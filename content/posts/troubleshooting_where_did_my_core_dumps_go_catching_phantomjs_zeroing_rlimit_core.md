+++
title = "[troubleshoot] Where did my core dumps go? Catching PhantomJS zeroing RLIMIT_CORE"
date = 2026-03-30
[taxonomies]
tags= ["linux", "troubleshoot"]
+++

# TL;DR
- configured `RLIMIT_CORE` on the container's root process to 40 GiB (`prlimit -c $(( 40 * 1024 * 1024 * 1024 ))`)
- yet got no core dumps when PhantomJS process terminated itself with `SIGABRT`
- the core dump handler registered in `/proc/sys/kernel/core_pattern` logged that `%c` (core file size soft resource limit) was `0`
- turned out (under `gdb`) PhantomJS makes a `setrlimit` call effectively zeroing its `RLIMIT_CORE`

# The problem
A cybersecurity engineer from a team that uses PhantomJS for their automated vulnerability analysis came to me with a problem.
From time to time the PhantomJS process in their pods crashed badly, mostly with `SIGABRT`.
He couldn't understand where his core dumps went and asked me to help him find out.

I entered the container and found the parent process. It was a Go application that ran PhantomJS via `execve()` as part of its job. Indeed, no core dumps were found in `/coredumps` directory where our core dump handler normally places them.

# First clue: core dump handler says `%c = 0`

In the logs of the core dump handler I saw that it logged `0` instead of `42949672960` (which corresponds to 40GiB) under `%c` in `core_pattern`, which stands for the core file size soft limit.
> `/proc/sys/kernel/core_pattern` is just a command that Linux pipes a fresh core dump to, while also giving it some arguments describing the core and the crashed process. It typically looks like this: `|/usr/lib/coredump-handler -c %c -p %p -e %e`. Linux substitutes `%c %p %e` and so on. `%e` is substituted by first 15 characters of the executable filename. More on that in `man 5 core`.
It instantly made me suspect problems with `RLIMIT_CORE` as this is the limit that Linux kernel's dumper takes into account when handling `SIGABRT` (and other signals with default signal action `SIG_DFL` to dump a core).

# Finding the binary

I straced the process to find the path to the PhantomJS binary it's trying to run.

```bash
$ sudo strace -f -e execve -p $(pgrep the-go-application-name)
# ...
[pid 259132] execve("/usr/bin/phantomjs/phantomjs", ["phantomjs", ...], 0x55858e2a6d70 /* 126 vars */) = 0
# ...
```

# Verifying that limits propagate correctly

After that I stepped into `gdb` that was available on the host. I wanted to see if `prlimit -c -p $(pgrep phantomjs)` changed somehow from my session's ulimit in order to check that propagation of limits worked as expected.

```bash
# Set RLIMIT_CORE for my current session
$ ulimit -c 123456
# Check that it's set
$ ulimit -c
123456
# Check that the limit is indeed propagating to child processes
$ echo "Current process: $$" && bash -c 'echo "Child process: $$" && ulimit -c'
Current process: 303405
Child process: 303408
123456
# Now run the phantomjs binary under gdb
$ gdb -q /usr/bin/phantomjs/phantomjs
Reading symbols from /usr/bin/phantomjs/phantomjs...
(No debugging symbols found in /usr/bin/phantomjs/phantomjs)
(gdb) # Add breakpoint to standard `_start` symbol entrypoint
(gdb) break _start
Function "_start" not defined.
Make breakpoint pending on future shared library load? (y or [n]) y
Breakpoint 1 (_start) pending.
(gdb) run
Starting program: /usr/bin/phantomjs/phantomjs 

Breakpoint 1, 0x00007ffff7fe3d40 in _start () from /lib64/ld-linux-x86-64.so.2
(gdb) # Let's get the PID of the inferior process to then see the limits
(gdb) info proc
process 33913
cmdline = '/usr/bin/phantomjs/phantomjs'
cwd = '/'
exe = '/usr/bin/phantomjs/phantomjs'
(gdb) shell cat /proc/33913/limits | grep core
Max core file size        126418944            126418944            bytes     
(gdb) shell echo $((126418944 / 1024))
123456
(gdb) quit
```

So the limit arrives correctly. Something inside PhantomJS changes it.

# Catching the culprit

There's a known syscall that allows programs to set these limits: `setrlimit` (`man 2 setrlimit`).
Code from the manpage:
```c
#include <sys/resource.h>

int getrlimit(int resource, struct rlimit *rlim);
int setrlimit(int resource, const struct rlimit *rlim);

int prlimit(pid_t pid, int resource,
const struct rlimit *_Nullable new_limit,
struct rlimit *_Nullable old_limit);

struct rlimit {
    rlim_t  rlim_cur;  /* Soft limit */
    rlim_t  rlim_max;  /* Hard limit (ceiling for rlim_cur) */
};

typedef /* ... */  rlim_t;  /* Unsigned integer type */
```

If I can catch PhantomJS calling this syscall then I can see what it sets as its new `RLIMIT_CORE`.
Let's see the actual `setrlimit` call:
```bash
$ gdb -q /usr/bin/phantomjs/phantomjs
Reading symbols from /usr/bin/phantomjs/phantomjs...
(No debugging symbols found in /usr/bin/phantomjs/phantomjs)
(gdb) break setrlimit
Breakpoint 1 at 0x18e10
(gdb) run
Starting program: /usr/bin/phantomjs/phantomjs
[Thread debugging using libthread_db enabled]
Using host libthread_db library "/lib/x86_64-linux-gnu/libthread_db.so.1".

Breakpoint 1, __setrlimit64 (resource=RLIMIT_CORE, rlimits=0x7fffffffe160) at ../sysdeps/unix/sysv/linux/setrlimit64.c:38
38      ../sysdeps/unix/sysv/linux/setrlimit64.c: No such file or directory.
(gdb) # Got it! Now need to pretty print the actual value
(gdb) info args
resource = RLIMIT_CORE
rlimits = 0x7fffffffe160
(gdb) print *(struct rlimit *)0x7fffffffe160
$1 = {rlim_cur = 0, rlim_max = 0}
(gdb) # 🎉
```

With this we can finally state that PhantomJS sets its own `RLIMIT_CORE` to `0` on startup.
And that's exactly the reason why no core dumps are produced.

# Conclusion

I showed the cybersec guy these outputs and explained what the problem was, warned him about the deprecation of PhantomJS.
The fix path was either patching PhantomJS's startup behavior (`LD_PRELOAD` a small injection that ignores `setrlimit` calls with `RLIMIT_CORE`) or migrating to a maintained headless browser (PhantomJS has been deprecated since 2018).

# Note
Although I used gdb to catch the `setrlimit` call, I could have caught it more easily with `strace`. I used `gdb` mostly because at the time I wasn't sure `setrlimit` was the culprit.

# Special thanks
A special thanks to my friend Yuri Fomichev who gave me an opportunity to troubleshoot this!

# Further reading
- `man 5 core` for the part about when core dump is not produced and how to use `/proc/sys/kernel/core_pattern`
- `man 7 signal` for table of default signal actions, such as `core` dump, `term`inate, `ign`ore, `stop` and `cont`inue.
