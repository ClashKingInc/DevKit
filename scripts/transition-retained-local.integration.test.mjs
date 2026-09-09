import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {resolve} from 'node:path';
import {test} from 'node:test';
import {switchDatabaseNames} from './transition-retained-local.mjs';

test('real PostgreSQL switch preserves both databases and connection policy', {skip:process.env.CLASHKING_DISPOSABLE_TIMESCALE!=='1'}, async()=>{
  const uri=new URL(process.env.TEST_DATABASE_URL);
  assert.equal(uri.hostname,'127.0.0.1');
  assert.notEqual(uri.port,'54329');
  assert.equal(uri.pathname,'/clashking_test');
  const require=createRequire(resolve(process.env.CLASHKING_API_REPO,'package.json'));
  const {Client}=require('pg');
  const admin=new Client({connectionString:uri.href});
  await admin.connect();
  try {
    await admin.query('CREATE DATABASE clashking_dev');
    await admin.query('CREATE DATABASE clashking_dev_candidate_007');
    const before=await admin.query("SELECT oid::text,datname FROM pg_database WHERE datname IN ('clashking_dev','clashking_dev_candidate_007')");
    await admin.query('ALTER DATABASE clashking_dev ALLOW_CONNECTIONS false');
    await switchDatabaseNames(admin);
    const after=await admin.query("SELECT oid::text,datname,datallowconn FROM pg_database WHERE datname IN ('clashking_dev','clashking_dev_retired_028')");
    assert.equal(after.rows.find(row=>row.datname==='clashking_dev').oid,before.rows.find(row=>row.datname==='clashking_dev_candidate_007').oid);
    assert.equal(after.rows.find(row=>row.datname==='clashking_dev_retired_028').oid,before.rows.find(row=>row.datname==='clashking_dev').oid);
    assert.equal(after.rows.find(row=>row.datname==='clashking_dev_retired_028').datallowconn,false);
    assert.equal(after.rows.find(row=>row.datname==='clashking_dev').datallowconn,true);
  } finally {
    // This test can run only in the schema-owned isolated container. Never force
    // termination; the outer fixture also removes its own temporary container.
    for(const name of ['clashking_dev','clashking_dev_candidate_007','clashking_dev_retired_028']) await admin.query(`DROP DATABASE IF EXISTS ${name}`);
    await admin.end();
  }
});
