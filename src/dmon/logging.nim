
when defined(noLogging):
  template notice*(msg: string, args: varargs[untyped]) = discard
  template warn*(msg: string, args: varargs[untyped]) = discard
  template debug*(msg: string, args: varargs[untyped]) = discard
  template info*(msg: string, args: varargs[untyped]) = discard
  template trace*(msg: string, args: varargs[untyped]) = discard
  template error*(msg: string, args: varargs[untyped]) = discard
else:
  import chroniclers
  export chroniclers
