import IOErr exposing [IOErr]
import OsStr exposing [OsStr]
## The raw spawn, and the fd numbers a redirect carries.
##
## Not an app export: `Fd(n)` is ambient authority in a form Roc cannot type
## (any descriptor this process holds, another component's socket included),
## and `FdHandoff`, which mints the numbers, is unimportable for the same
## reason (D-S2-14, D-S2-21, D-S2-45). Apps spawn through `Subprocess.spawn!`,
## whose `Stdio` names resources instead.
SubprocessRaw :: [].{
	## The command as the host takes it; `Subprocess.Cmd` is this type. `envs`
	## is a flat list of key and value, one after the other, and a trailing
	## unpaired name is dropped.
	Cmd : { args : List(OsStr), clear_envs : Bool, envs : List(OsStr), program : OsStr }
	## Where one of a child's standard streams goes, as the host takes it. An
	## `Fd` is borrowed: the host duplicates it for the child and never closes
	## it, so a number an app made up cannot close anything.
	Redirect : [Inherit, Null, Pipe, Fd(I32)]
	## The host's handle on a running or finished child. Dropping it neither
	## kills nor reaps the child.
	Handle :: Box(U64)

	spawn_redirected! : Cmd, { stdin : Redirect, stdout : Redirect, stderr : Redirect } => Try(Handle, [Io(IOErr)])
}
