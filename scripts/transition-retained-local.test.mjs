import assert from 'node:assert/strict';
import {test} from 'node:test';
import {validateTransitionArguments, switchDatabaseNames} from './transition-retained-local.mjs';

test('local transition is explicit and does not accept target overrides',()=>{
  assert.doesNotThrow(()=>validateTransitionArguments(['--approve-local-007-switch']));
  for(const args of [[],['up'],['--approve-local-007-switch','--database','production']]) assert.throws(()=>validateTransitionArguments(args));
});

test('database renames run outside a transaction',async()=>{
  const commands=[];
  await switchDatabaseNames({async query(sql){commands.push(sql);}});
  assert.deepEqual(commands,[
    'ALTER DATABASE clashking_dev RENAME TO clashking_dev_retired_028',
    'ALTER DATABASE clashking_dev_candidate_007 RENAME TO clashking_dev',
  ]);
});

test('a failed second rename explicitly restores the original name',async()=>{
  const commands=[];
  await assert.rejects(switchDatabaseNames({async query(sql){commands.push(sql);if(sql.startsWith('ALTER DATABASE clashking_dev_candidate'))throw Error('busy candidate');}}),/busy candidate/);
  assert.deepEqual(commands,[
    'ALTER DATABASE clashking_dev RENAME TO clashking_dev_retired_028',
    'ALTER DATABASE clashking_dev_candidate_007 RENAME TO clashking_dev',
    'ALTER DATABASE clashking_dev_retired_028 RENAME TO clashking_dev',
  ]);
});

test('a failed compensating rename reports both failures and retained source name',async()=>{
  await assert.rejects(
    switchDatabaseNames({async query(sql){
      if(sql.includes('candidate_007') || sql.includes('retired_028 RENAME')) throw Error(sql);
    }}),
    error=>error instanceof AggregateError && error.errors.length===2 && error.message.includes('source data remains in clashking_dev_retired_028'),
  );
});
