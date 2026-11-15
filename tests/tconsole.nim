import std/[json, strutils, unittest]
import ../lib/[console_dump, console_scheduler, console_state, console_tasks]

suite "redact":
  let a36 = "A".repeat(36)
  proc redacted(s: string): string = redact(s)[0]

  test "トークンは 36 文字以上の英数字が続くときだけ伏せる":
    check redacted("ok ghp_" & a36 & " end") == "ok *** end"
    check redacted("short ghp_" & "B".repeat(35)) == "short ghp_" & "B".repeat(35)
  test "前が単語の文字なら伏せない":
    check redacted("xghp_" & a36) == "xghp_" & a36
    check redacted("-ghp_" & a36 & "-") == "-***-"
    check redacted("日本語ghp_" & a36 & "の後") == "日本語***の後"
  test "続けて書かれたトークンは、英数字の続く分だけ 1 つに伏せる":
    check redacted("ghp_" & a36 & "ghp_" & a36) == "***_" & a36
  test "github_pat_ と sk-ant- の長さの下限":
    check redacted("github_pat_" & "C".repeat(22) & "_x") == "***"
    check redacted("github_pat_" & "D".repeat(21)) == "github_pat_" & "D".repeat(21)
    check redacted("sk-ant-api03-" & "e".repeat(20) & "--zz and sk-ant-abc") == "*** and sk-ant-abc"
  test "秘密鍵は BEGIN から最初に閉じる END までを伏せる":
    check redacted("-----BEGIN RSA PRIVATE KEY-----\nx\n-----END RSA PRIVATE KEY-----\n") == "***\n"
    check redacted("-----BEGIN PRIVATE KEY-----a-----END PRIVATE KEY----------BEGIN PRIVATE KEY-----b-----END PRIVATE KEY-----") == "******"
    check redacted("-----BEGIN PUBLIC KEY-----\nz\n-----END PUBLIC KEY-----") == "-----BEGIN PUBLIC KEY-----\nz\n-----END PUBLIC KEY-----"
  test "閉じていない BEGIN は、後ろにある END まで伏せる":
    check redacted("-----BEGIN PRIVATE KEY-----\nopen\n-----END PRIVATE KEY----- stray") == "*** stray"
  test "伏せた数を返す":
    check redact("ghp_" & a36 & " sk-ant-" & "e".repeat(20))[1] == 2

suite "sanitizeUtf8":
  test "正しい UTF-8 はそのまま":
    check sanitizeUtf8("あいう abc") == "あいう abc"
  test "不正なバイトと途中で切れた文字を U+FFFD にする":
    check sanitizeUtf8("a\xff\xfeb\xe3\x81") == "a��b�"
  test "サロゲートの符号化は不正":
    check sanitizeUtf8("\xed\xa0\x80") == "���"

suite "pySplitLines":
  test "末尾の改行で空行を作らず、\\r と \\r\\n でも分ける":
    check pySplitLines("a\nb\r\nc\rd\n") == @["a", "b", "c", "d"]
    check pySplitLines("a\n\nb") == @["a", "", "b"]
    check pySplitLines("").len == 0

suite "pyDumps":
  test "区切りに空白を入れ、制御文字を \\u でエスケープする":
    check pyDumps(%*{"a": [1, "x\u0001"], "b": true, "c": nil, "d": 1.5}) ==
      """{"a": [1, "x\u0001"], "b": true, "c": null, "d": 1.5}"""

suite "truncateText":
  test "文字数で切って印を付ける":
    check truncateText("あいうえお", 3) == "あいう …"
    check truncateText("あいう", 3) == "あいう"

suite "stripAnsiLines":
  test "最後に効いた色でレベルを決め、m で終わる色だけを消す":
    check stripAnsiLines("\e[33m警告\e[0m と \e[1;31m失敗\e[0m と \e[31;33mまぜ\e[0m\n\e[2K消す\n") == %*[
      {"text": "警告 と 失敗 と まぜ", "level": "warn"},
      {"text": "\e[2K消す", "level": "info"},
    ]
