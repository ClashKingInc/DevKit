"""Keep Elasticsearch's already-absent delete result safe to replay."""
import ast
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path

path = Path(distribution('pgsync').locate_file('pgsync/search_client.py'))
source = path.read_text()
node = next(node for node in ast.walk(ast.parse(source)) if isinstance(node, ast.FunctionDef) and node.name == '__init__')
original = ''.join(source.splitlines(keepends=True)[node.lineno - 1:node.end_lineno])
if sha256(original.encode()).hexdigest() != '408ee3580ef6b9b3351bc2a0b493bc4d42bb9bd7e7b12e6e1cc8dd50544e7cca':
    raise RuntimeError('PGSync search initialization changed; review the delete replay patch')
if source.count('elasticsearch.helpers.streaming_bulk') != 1:
    raise RuntimeError('Expected exactly one Elasticsearch streaming-bulk binding')
source = source.replace('elasticsearch.helpers.streaming_bulk', '_clashking_streaming_bulk', 1)
helper = '''def _clashking_streaming_bulk(client, actions, **kwargs):
    """Accept only an already-absent delete; preserve every other failure."""
    raise_on_error = kwargs.pop("raise_on_error", True)
    for ok, item in elasticsearch.helpers.streaming_bulk(
        client, actions, raise_on_error=False, **kwargs,
    ):
        if not ok:
            operation, result = next(iter(item.items()))
            # A fresh index can already reflect an old WAL deletion. Replaying
            # that delete is complete. Do not ignore all 404s: a missing index,
            # failed update, or other error must still prevent checkpointing.
            if (operation == "delete" and result.get("status") == 404
                    and result.get("result") == "not_found"
                    and not result.get("error")):
                yield True, item
                continue
            if raise_on_error:
                raise elasticsearch.helpers.BulkIndexError(
                    "1 document(s) failed to index.", [item],
                )
        yield ok, item


'''
source = source.replace('class SearchClient(object):', helper + 'class SearchClient(object):', 1)
compile(source, str(path), 'exec')
path.write_text(source)
print('Applied reviewed Elasticsearch absent-delete replay patch')
