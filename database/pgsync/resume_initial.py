"""Finish an interrupted initial forward pass without guessing a checkpoint."""
import argparse
import json
import logging
from collections import Counter
from elasticsearch.helpers import BulkIndexError
import os
import re
import sqlalchemy as sa
from pgsync import settings
from pgsync.sync import Sync
from pgsync.utils import config_loader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--index', required=True)
    parser.add_argument('--expect-database', required=True)
    parser.add_argument('--expect-host', required=True)
    parser.add_argument('--expect-system-id', required=True)
    parser.add_argument('--expect-index-count', type=int, required=True)
    parser.add_argument('--through-xid', type=int, required=True)
    parser.add_argument('--through-lsn', required=True)
    parser.add_argument('--confirm-forward-pass-complete', action='store_true')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--mode', choices=('preview', 'apply'), default='preview')
    parser.add_argument('--forward-pass-confirmation', default='unconfirmed')
    args = parser.parse_args()
    args.apply = args.apply or args.mode == 'apply'
    args.confirm_forward_pass_complete = args.confirm_forward_pass_complete or args.forward_pass_confirmation == 'completed-forward-pass'
    if not settings.REDIS_CHECKPOINT or os.environ.get('PG_HOST') != args.expect_host:
        raise RuntimeError('Explicit host and Redis checkpoint configuration required')
    if args.through_xid <= 0 or not re.fullmatch(r'[0-9A-Fa-f]+/[0-9A-Fa-f]+', args.through_lsn):
        raise RuntimeError('Invalid observed XID/LSN boundary')
    docs = [doc for doc in config_loader(args.config) if doc.get('index') == args.index]
    if len(docs) != 1 or docs[0]['database'] != args.expect_database:
        raise RuntimeError('Exact configured index/database required')
    # Constructor validation can create settings or a temporary slot. This
    # preview performs explicit read-only checks instead; it never bootstraps.
    sync = Sync(docs[0], validate=False)
    slot_name = re.sub('[^0-9a-zA-Z_]+', '', f'{args.expect_database.lower()}_{args.index}')
    with sync.engine.connect() as conn:
        identity = conn.execute(sa.text('SELECT current_database(),system_identifier::text FROM pg_control_system()')).one()
        if tuple(identity) != (args.expect_database, args.expect_system_id):
            raise RuntimeError('Database cluster identity mismatch')
        slot = conn.execute(sa.text('''SELECT database,plugin,active,invalidation_reason,
            restart_lsn IS NOT NULL AS retained,
            confirmed_flush_lsn <= CAST(:lsn AS pg_lsn) AS before_boundary
            FROM pg_replication_slots WHERE slot_name=:slot'''), {'lsn': args.through_lsn, 'slot': slot_name}).mappings().one()
        boundary = conn.execute(sa.text('SELECT CAST(:lsn AS pg_lsn)<=pg_current_wal_lsn() AND :xid<=txid_current()'), {'lsn': args.through_lsn, 'xid': args.through_xid}).scalar_one()
        if slot['database'] != args.expect_database or slot['plugin'] != 'test_decoding' or slot['active'] or slot['invalidation_reason'] or not slot['retained'] or not slot['before_boundary'] or not boundary:
            raise RuntimeError('Stopped valid slot and observed non-future boundary required')
    key = sync.redis.key + ':meta'
    if sync.redis.client.type(key) not in (b'none', b'hash', 'none', 'hash'):
        raise RuntimeError('Unexpected checkpoint storage type; refusing automatic repair')
    checkpoint = sync.checkpoint
    if checkpoint == args.through_xid:
        print(json.dumps({'index': args.index, 'already_complete': True, 'checkpoint': checkpoint}))
        return
    if checkpoint is not None:
        raise RuntimeError('This command only resumes a proven initial forward pass')
    result = sync.search_client.search(args.index, {'size': 0, 'track_total_hits': True, 'query': {'match_all': {}}})
    count = result['hits']['total']['value']
    if count != args.expect_index_count:
        raise RuntimeError('Index changed since the stopped forward-pass evidence was recorded')
    print(json.dumps({'index': args.index, 'apply': args.apply, 'count': count, 'checkpoint_before': checkpoint, 'through_xid': args.through_xid, 'through_lsn': args.through_lsn}), flush=True)
    if not args.apply:
        return
    if not args.confirm_forward_pass_complete:
        raise RuntimeError('Explicit confirmation of the completed forward pass is required')
    # These are the exact arguments observed in the interrupted pull(), not a
    # newly chosen horizon. The normal method indexes before consuming the slot
    # and setting its checkpoint. Failures remain retryable from the same slot.
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        sync.logical_slot_changes(txmin=None, txmax=args.through_xid, upto_lsn=args.through_lsn)
    except BulkIndexError as error:
        # Error metadata is sufficient for operations; never print source docs,
        # player names, IDs, or an Elasticsearch reason containing field values.
        failures = Counter()
        for item in error.errors:
            operation, result = next(iter(item.items()))
            detail = result.get('error') or {}
            error_type = detail.get('type') if isinstance(detail, dict) else 'unknown'
            failures[(operation, result.get('status'), error_type, result.get('result'))] += 1
        print(json.dumps({'failed_bulk': [dict(operation=k[0], status=k[1], error_type=k[2], result=k[3], count=v) for k, v in failures.items()]}), flush=True)
        raise
    if sync.checkpoint != args.through_xid:
        raise RuntimeError('Catch-up did not persist its expected checkpoint')
    print(json.dumps({'index': args.index, 'complete': True, 'checkpoint': sync.checkpoint}))


if __name__ == '__main__':
    main()
