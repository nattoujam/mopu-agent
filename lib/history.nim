import std/[json, strutils]

proc text*(node: JsonNode): string =
  if node == nil or node.kind == JNull: "null"
  elif node.kind == JString: node.getStr
  else: $node

proc quoteLines*(s: string): string =
  if s.len == 0: "" else: "> " & s.replace("\n", "\n> ")

# コメントの本文は見出しやコードフェンスを含むので、引用にして周りの見出しと混ざらないようにする
proc renderHistory*(task: JsonNode): string =
  let rows = task{"history"}
  if rows == nil or rows.kind != JArray:
    return ""
  for h in rows:
    let byAgent = h{"by_agent"}
    let who = if byAgent != nil and byAgent.kind == JBool and byAgent.getBool: "mopu-agent の投稿"
              else: text(h{"actor"})
    result.add "#### " & who & "（" & text(h{"created_at"}) & "）\n" & text(h{"url"}) & "\n\n" &
      quoteLines(h{"body"}.getStr) & "\n\n"
  result = result.strip(leading = false, chars = {'\n'})
