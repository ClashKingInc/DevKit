import test from 'node:test';import assert from 'node:assert/strict';
import {r2Config,validateManifest}from'../src/dataset.mjs';
test('public backup needs no credentials and rejects S3 endpoint',()=>{
 const e={DATASET_R2_BUCKET:'clashking-bucket',R2_ENDPOINT:'https://downloads.example.com'};
 assert.equal(r2Config(e).endpoint,'https://downloads.example.com/');assert.equal(r2Config(e).env,undefined);assert.throws(()=>r2Config({...e,R2_ENDPOINT:'https://abc.r2.cloudflarestorage.com'}));
});
test('starter manifest stays in database prefix and requires checksum',()=>{
 const m={key:'database/starter-20260920.dump.gpg',sha256:'a'.repeat(64)};assert.equal(validateManifest(m),m);
 for(const key of ['../secret','other/file.dump.gpg','database/../../x.dump.gpg'])assert.throws(()=>validateManifest({...m,key}));assert.throws(()=>validateManifest({...m,sha256:'bad'}));
});
