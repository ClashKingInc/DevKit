import assert from 'node:assert/strict';
import {test} from 'node:test';
import {validateTransferTargets, quoteIdentifier, transferProjection} from './transfer-retained-local.mjs';

test('retained source is read-only and destination must be an isolated fixture', () => {
  const source='postgres://clashking_local:clashking_local@127.0.0.1:54329/clashking_dev';
  const target='postgres://clashking_test:clashking_test@127.0.0.1:55432/clashking_test';
  assert.doesNotThrow(()=>validateTransferTargets(source,target,{CLASHKING_DISPOSABLE_TIMESCALE:'1'}));
  for (const invalid of [source,target.replace('127.0.0.1','152.53.82.182'),target.replace('clashking_test','postgres')]) {
    assert.throws(()=>validateTransferTargets(source,invalid,{CLASHKING_DISPOSABLE_TIMESCALE:'1'}));
  }
  assert.throws(()=>validateTransferTargets(source,target,{}));
  assert.throws(()=>validateTransferTargets(source.replace('54329','5432'),target,{CLASHKING_DISPOSABLE_TIMESCALE:'1'}));
});

test('catalog identifiers remain quoted SQL identifiers',()=>{
  assert.equal(quoteIdentifier('strange"column'),'"strange""column"');
});

test('persistent candidate requires explicit approval and cannot target the retained database',()=>{
  const source='postgres://clashking_local:clashking_local@127.0.0.1:54329/clashking_dev';
  const candidate=source.replace('/clashking_dev','/clashking_dev_candidate_007');
  assert.throws(()=>validateTransferTargets(source,candidate,{}));
  assert.doesNotThrow(()=>validateTransferTargets(source,candidate,{CLASHKING_RETAINED_CANDIDATE:'approved-local-007'}));
  assert.throws(()=>validateTransferTargets(source,source,{CLASHKING_RETAINED_CANDIDATE:'approved-local-007'}));
  assert.throws(()=>validateTransferTargets(source,candidate.replace('54329','54330'),{CLASHKING_RETAINED_CANDIDATE:'approved-local-007'}));
});

test('transport distinguishes SQL null from JSON null and keeps bigint precision',()=>{
  const wire=transferProjection({types:{search:'jsonb',id:'bigint'}},['search','id']);
  assert.equal(wire.source,'"search"::text AS "search","id"::text AS "id"');
  assert.equal(wire.incoming,'"search" text,"id" text');
  assert.deepEqual(wire.decoded,['incoming."search"::jsonb','incoming."id"::bigint']);
  assert.throws(()=>transferProjection({types:{}},['search']),/Missing catalog type/);
});
