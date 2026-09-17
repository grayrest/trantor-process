# A child starts with no signals blocked, whatever the app's thread blocks.
#
# trantor-terminal blocks SIGWINCH on the thread that opens the terminal and
# receives it on a thread of its own, so a resize never interrupts a blocking
# call (trantor D-K1-29). std's Command hands the parent's mask to the child,
# so vim started from such an app would never see a resize. A Roc app cannot
# block a signal itself, so anything blocked is a host's own business and
# subprocess-host clears all of it.
#
# The app is run with SIGWINCH and SIGUSR1 already blocked, which exec passes
# on just as a host's block would, and both children report their mask.
source ../lib.sh
new_project
build_app app.roc mask
readonly WINCH_AND_USR1=3
blocked() { perl -MPOSIX -e 'sigprocmask(SIG_BLOCK, POSIX::SigSet->new(SIGWINCH, SIGUSR1)); exec @ARGV or die "exec: $!"' "$@"; }
# The reporter itself under the same block: without this a broken block would
# let the check below pass.
direct=$(blocked perl -MPOSIX -e 'my $s = POSIX::SigSet->new; sigprocmask(SIG_BLOCK, undef, $s); print(($s->ismember(SIGWINCH) ? 1 : 0) + ($s->ismember(SIGUSR1) ? 2 : 0))')
[[ "$direct" == "$WINCH_AND_USR1" ]] || { echo "FAIL: the blocking wrapper left mask $direct, want $WINCH_AND_USR1 — the check proves nothing"; exit 1; }
read -r printed exited <<<"$(blocked "$(bin mask)")"
[[ "$printed" == 0 ]] || { echo "FAIL: exec_output!'s child started with mask $printed (1 SIGWINCH, 2 SIGUSR1), want 0"; exit 1; }
[[ "$exited" == 0 ]] || { echo "FAIL: exec_exit_code!'s child started with mask $exited (1 SIGWINCH, 2 SIGUSR1), want 0"; exit 1; }
echo "ok: a child starts with an empty signal mask when the app's thread has SIGWINCH and SIGUSR1 blocked"
