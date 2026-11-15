import std/[os, strutils]

task build, "bin/mopu をビルドする":
  exec "nim c --hints:off -d:release --out:bin/mopu lib/mopu.nim"

task test, "bin/mopu をビルドし、tests/t*.nim を実行する":
  exec "nim c --hints:off -d:release --out:bin/mopu lib/mopu.nim"
  for f in listFiles("tests"):
    let name = f.extractFilename
    if name.startsWith("t") and name.endsWith(".nim"):
      exec "nim r --hints:off " & f
