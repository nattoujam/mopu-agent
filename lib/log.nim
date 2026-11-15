import std/times

type Fatal* = object of CatchableError

proc stamp(): string = now().format("HH:mm:ss")

proc localStamp*(): string = now().format("yyyy-MM-dd'T'HH:mm:sszzz")

proc log*(msg: string) = stderr.writeLine stamp() & " " & msg
proc warn*(msg: string) = stderr.writeLine stamp() & " \e[33m" & msg & "\e[0m"
proc err*(msg: string) = stderr.writeLine stamp() & " \e[31m" & msg & "\e[0m"

proc die*(msg: string) {.noreturn.} =
  raise newException(Fatal, msg)
