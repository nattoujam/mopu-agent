import std/[os, strutils]

const root = currentSourcePath().parentDir.parentDir

proc commit(): string {.compileTime.} =
  result = staticExec("git -C " & root & " rev-parse --short HEAD").strip
  if result.len == 0:
    return "unknown"
  if staticExec("git -C " & root & " status --porcelain").strip.len > 0:
    result.add "-dirty"

proc collect(dir: string): seq[(string, string)] {.compileTime.} =
  for path in walkDirRec(root / dir, relative = true):
    result.add (path, staticRead(root / dir / path))

const
  Prompts = collect("prompts")
  SchemaJson* = staticRead(root / "settings" / "schema.json")
  AgentSettingsJson* = staticRead(root / "settings" / "agent-settings.json")
  StatesJson* = staticRead(root / "lib" / "states.json")
  IndexHtml* = staticRead(root / "web" / "index.html")
  Version* = staticRead(root / "VERSION").strip
  Commit* = commit()

proc prompt*(name: string): string =
  for (n, text) in Prompts:
    if n == name:
      return text
  raise newException(KeyError, "prompts にありません: " & name)
