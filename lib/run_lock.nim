import std/[options, os, posix]
import paths

var
  LOCK_EX {.importc, header: "<sys/file.h>".}: cint
  LOCK_NB {.importc, header: "<sys/file.h>".}: cint
  LOCK_UN {.importc, header: "<sys/file.h>".}: cint

proc flock(fd, op: cint): cint {.importc, header: "<sys/file.h>".}

proc tryLockPoll*(): Option[cint] =
  createDir(stateDir)
  let fd = posix.open(pollLock.cstring, O_RDWR or O_CREAT, 0o644)
  if fd < 0:
    raiseOSError(osLastError())
  if flock(fd, LOCK_EX or LOCK_NB) != 0:
    discard posix.close(fd)
    return none(cint)
  some(fd)

proc unlockPoll*(fd: cint) =
  discard flock(fd, LOCK_UN)
  discard posix.close(fd)

proc pollLockHeld*(): bool =
  try:
    let fd = tryLockPoll()
    if fd.isNone:
      return true
    unlockPoll(fd.get)
    false
  except OSError:
    false
