import assert from 'node:assert/strict';
import {test} from 'node:test';
import {validateTransitionArguments, switchDatabaseNames} from './transition-retained-local.mjs';

test('local transition is explicit and does not accept target overrides',()=>{
  assert.doesNotThrow(()=>validateTransitionArguments(['--approve-local-007-switch']));
  for(const args of [[],['up'],['--approve-local-007-switch','--database','production']]) assert.throws(()=>validateTransitionArguments(args));
});

test('a failed second rename rolls the first rename back',async()=>{
  const commands=[];
  await assert.rejects(switchDatabaseNames({async query(sql){commands.push(sql);if(sql.startsWith('ALTER DATABASE clashking_dev_candidate'))throw Error('busy candidate');}}),/busy candidate/);
  assert.equal(commands[0],'BEGIN');
  assert.equal(commands.at(-1),'ROLLBACK');
  assert.equal(commands.includes('COMMIT'),false);
});
