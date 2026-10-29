'use strict';
const base = Date.parse('2026-05-20T10:00:00Z');
const time = seconds => new Date(base + seconds * 1000).toISOString().replace('.000Z', '');
const meta = { dbName: 'SYNTHETIC', beginTime: time(0), endTime: time(120), sqlText: { waitsql: 'update orders set status = :1', rootsql: 'select * from accounts' } };
function row(seconds = 0, fields = {}) {
  return Object.assign({ t: time(seconds), inst: 1, sid: 20, serial: 200, bInst: 1, bSid: 10, bSer: 100,
    conId: 3, ev: 'enq: TX - row lock contention', wc: 'Application', sqlId: 'waitsql', user: 'APP', module: 'ORDERS', action: 'UPDATE',
    bUser: 'APP', bMod: 'ROOT', snapId: 10, sampleId: seconds + 1, p1: 1415053318, p2: 65538, p3: 3,
    xid: '0001000200030000', bXid: '0001000200040000', obj: 'APP.ORDERS', dObj: 123, curFile: 4, curBlock: 5, curRow: 6 }, fields);
}
const fanIn = [0, 10, 20].flatMap(t => Array.from({ length: 6 }, (_, i) => row(t, { sid: 20 + i, serial: 200 + i, module: 'FANIN' })).concat(row(t, { sid: 80, serial: 800, bSid: 70, bSer: 700, module: 'OTHER' })));
const changing = [row(0), row(0, { sid: 10, serial: 100, bSid: 5, bSer: 50 }), row(10, { bSid: 30, bSer: 300 }), row(20, { sid: 10, serial: 100, bSid: 20, bSer: 200 }), row(20)];
module.exports = { base, time, meta, row, fanIn, changing };
