"""Patch the pinned PGSync release's repeated WAL scans at image build time."""
from hashlib import sha256
import ast
from importlib.metadata import distribution
from pathlib import Path
source_path = Path(distribution("pgsync").locate_file("pgsync/sync.py"))
source = source_path.read_text()
class_node = next(node for node in ast.parse(source).body if isinstance(node, ast.ClassDef) and node.name == "Sync")
method = next(node for node in class_node.body if isinstance(node, ast.FunctionDef) and node.name == "logical_slot_changes")
original = "".join(source.splitlines(keepends=True)[method.lineno - 1:method.end_lineno])
expected = "a20ea9000f8b6b7d9fe26d109d976831929178b59dfc355281e776e6e89337ad"
if sha256(original.encode()).hexdigest() != expected:
    raise RuntimeError("PGSync catch-up implementation changed; review the patch before upgrading")
replacement = '''    def logical_slot_changes(
        self,
        txmin: t.Optional[int] = None,
        txmax: t.Optional[int] = None,
        upto_lsn: t.Optional[str] = None,
        logical_slot_chunk_size: t.Optional[int] = None,
    ) -> None:
        """Read one bounded cursor, then consume only after all indexing succeeds."""
        limit = logical_slot_chunk_size or settings.LOGICAL_SLOT_CHUNK_SIZE
        current = 0
        # OFFSET over pg_logical_slot_peek_changes decodes the entire retained
        # WAL again for every page. Stream one query instead; fetch batches keep
        # Python memory bounded. The PostgreSQL function may still use temp disk.
        with self.advisory_lock(self.__name, max_retries=None, retry_interval=0.1):
            statement = self._logical_slot_changes(
                self.__name, sa.func.PG_LOGICAL_SLOT_PEEK_CHANGES,
                txmin=txmin, txmax=txmax, upto_lsn=upto_lsn,
            )
            with self.engine.connect() as connection:
                connection = connection.execution_options(
                    stream_results=True, yield_per=limit,
                )
                with connection.execute(statement) as rows:
                    for raw in rows.partitions(limit):
                        payloads: t.List[Payload] = []
                        for row in raw:
                            if TX_BOUNDARY_RE.match(row.data) or LOGICAL_MSG_RE.match(row.data):
                                continue
                            payload = self.parse_logical_slot(row.data)
                            if payload.schema in self.tree.schemas:
                                payloads.append(payload)
                        for _, run in groupby(
                            payloads, key=lambda payload: (payload.tg_op, payload.table),
                        ):
                            batch = list(run)
                            self.search_client.bulk(self.index, self._payloads(batch))
                            current += len(batch)
                            self.count["xlog"] += len(batch)
                        logger.info("WAL catch-up %s: processed %s change records", self.index, current)
        # A failed parse or bulk request exits before either operation below.
        # Replaying a successful partial batch is safe because document IDs are
        # stable. Never advance the slot or checkpoint to make an error disappear.
        self.logical_slot_get_changes(
            slot_name=self.__name, txmin=txmin, txmax=txmax, upto_lsn=upto_lsn,
        )
        self.checkpoint = txmax or self.txid_current
'''
if source.count(original) != 1:
    raise RuntimeError("Expected one PGSync catch-up method")
source = source.replace(original, replacement)
compile(source, str(source_path), "exec")
source_path.write_text(source)
print("Applied reviewed single-pass PGSync catch-up patch")
