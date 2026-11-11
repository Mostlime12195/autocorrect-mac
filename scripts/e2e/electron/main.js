// E2E Electron target (CI): a focused <textarea>; scripts/e2e/typing_target --post-only types into it. Once the text
// stops changing it's compared word by word with what it should become. WANT must match typing_target.swift.
const { app, BrowserWindow } = require('electron')
const TYPED = 'can you hlep me with teh thing becuase i dont know and im sure it is wierd so i think youre right and thats it '
const WANT = 'can you help me with the thing because I don\'t know and I\'m sure it is weird so I think you\'re right and that\'s it '

app.whenReady().then(async () => {
  const w = new BrowserWindow({ width: 900, height: 300, title: 'Keylime e2e (Electron)' })
  await w.loadURL('data:text/html,' + encodeURIComponent(
    '<textarea id=t spellcheck=false style="width:95%;height:250px;font-size:16px"></textarea>'))
  w.show(); w.focus(); app.focus({ steal: true })
  await w.webContents.executeJavaScript('document.getElementById("t").focus()')
  console.log('e2e electron: ready')
  let last = '', same = 0
  const t0 = Date.now()
  const iv = setInterval(async () => {
    const v = await w.webContents.executeJavaScript('document.getElementById("t").value')
    same = v === last && v.length > 0 ? same + 1 : 0
    last = v
    if (same >= 12 || Date.now() - t0 > 90000) {
      clearInterval(iv)
      const t = TYPED.split(' '), g = v.split(' '), wa = WANT.split(' ')
      let fixes = 0, targets = 0, wrong = 0
      for (let i = 0; i < t.length; i++) {
        if (t[i] === wa[i]) { if (g[i] !== undefined && g[i] !== wa[i]) { wrong++; console.log(`e2e electron: changed '${t[i]}' -> '${g[i]}'`) } continue }
        targets++
        if (g[i] === wa[i]) fixes++; else console.log(`e2e electron: missed '${t[i]}' -> '${g[i]}' (want '${wa[i]}')`)
      }
      console.log('e2e electron: got  ' + JSON.stringify(v))
      console.log('e2e electron: want ' + JSON.stringify(WANT))
      console.log(`E2E RESULT electron: ${fixes} of ${targets} typos fixed, ${wrong} correct words changed`)
      app.quit()
    }
  }, 500)
})
