const {chromium}=require(process.env.ASH_PLAYWRIGHT_PATH || 'playwright');
const fs=require('node:fs'), path=require('node:path'), assert=require('node:assert/strict');
const root=path.resolve(__dirname, '..');
const artifacts=process.env.ASH_BROWSER_ARTIFACTS || fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'ash-browser-'));
fs.mkdirSync(artifacts,{recursive:true});
(async()=>{
const browser=await chromium.launch({headless:true, ...(process.env.ASH_CHROMIUM_PATH ? {executablePath:process.env.ASH_CHROMIUM_PATH} : {})});
try {
 const context=await browser.newContext({viewport:{width:1440,height:1000},acceptDownloads:true,offline:true});
 const page=await context.newPage(), errors=[],requests=[];
 page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(/^https?:/.test(r.url()))requests.push(r.url());});
 await page.goto('file://'+root+'/reports/ash_blocking_demo.html');
 await page.waitForFunction(()=>document.querySelector('#kpis').textContent.includes('Blocked samples'));
 assert.equal(await page.evaluate(()=>echarts.version),'5.5.0');
 assert.equal(await page.locator('canvas').count(),3);
 await page.screenshot({path:path.join(artifacts,'desktop.png'),fullPage:true});
 const row=await page.evaluate(()=>window.ASH_DATA.find(r=>r.module&&r.svc&&r.obj&&r.sqlId));
 for(const [id,k] of [['Container','conId'],['Service','svc'],['Module','module'],['Object','obj'],['Sql','sqlId']])await page.selectOption('#filter'+id,String(row[k]));
 const count=await page.evaluate(r=>window.ASH_DATA.filter(x=>['conId','svc','module','obj','sqlId'].every(k=>x[k]===r[k])).length,row);
 assert.match(await page.locator('#scopeCount').innerText(),new RegExp('^'+count+' matching'));
 await page.selectOption('#episodeSelect','0');
 await page.locator('#investigation summary').click();
 let downloaded=page.waitForEvent('download'); await page.click('#briefDownload'); let download=await downloaded;
 const markdown=fs.readFileSync(await download.path(),'utf8'); assert.match(markdown,/Investigation SQL/);
 assert.equal(markdown,await page.locator('#briefText').inputValue());
 await page.check('#briefRedact'); downloaded=page.waitForEvent('download'); await page.click('#briefDownload'); download=await downloaded;
 const redacted=fs.readFileSync(await download.path(),'utf8'); assert.match(redacted,/aggregate-only/); assert.ok(!redacted.includes(row.module)); assert.ok(!redacted.includes('```'));
 // A module from a different service gives an empty combined scope.
 const other=await page.evaluate(r=>window.ASH_DATA.find(x=>x.module!==r.module&&!window.ASH_DATA.some(y=>y.module===x.module&&y.svc===r.svc))?.module,row);
 if(other){await page.selectOption('#filterModule',other);assert.match(await page.locator('#scopeCount').innerText(),/^0 matching/);await page.selectOption('#colorBy','module');}
 await page.click('#scopeReset');assert.match(await page.locator('#scopeCount').innerText(),/^1028 matching/);
 await page.fill('#sessSearch','ORDERS');await page.waitForFunction(()=>document.querySelector('#sessMatch').textContent.includes('sessions'));
 await page.locator('#sessSearch').press('Enter');
 await page.locator('#treePanel').focus();await page.keyboard.press('ArrowRight');
 await page.fill('#sessSearch','');
 await page.setViewportSize({width:390,height:844});
 await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 await page.waitForFunction(()=>document.documentElement.scrollWidth<=innerWidth);
 await page.screenshot({path:path.join(artifacts,'mobile.png'),fullPage:false});
 console.log(JSON.stringify({artifacts,errors,requests,desktopCharts:3,filteredRows:count,downloadBytes:markdown.length,redactedBytes:redacted.length,mobileOverflow:await page.evaluate(()=>({scroll:document.documentElement.scrollWidth,viewport:innerWidth}))}));
 assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);
} finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
