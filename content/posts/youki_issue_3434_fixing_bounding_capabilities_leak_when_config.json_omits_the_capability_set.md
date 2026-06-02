+++
title = "[youki] Fixing bounding capabilities leak when `config.json` omits the capability set"
date = 2026-05-27
[taxonomies]
tags= ["youki", "rust", "containers", "linux"]
+++

> - issue: [#3434:failed to drop capabilities in youki exec](https://github.com/youki-dev/youki/issues/3434)
> - fix: [#3554:drop bounding caps by default if unset](https://github.com/youki-dev/youki/pull/3554)

# TL;DR
- `youki`'s `run` and `exec` paths handled a missing `.process.capabilities.bounding` inconsistently
- `youki run` didn't touch the bounding capabilities set while `youki exec` correctly dropped all bounding capabilities
- solution is to default unset bounding capabilities to an empty set

# Comparison table for clarity

| command       |\|| reaction to unset bounding        |\|| result                  |
|:--------------|--|:---------------------------------:|--|:------------------------|
| `! runc run`  |\|| drop all bounding caps            |\|| failure (👍)            |
| `! youki exec`|\|| drop all bounding caps            |\|| failure (👍)            |
| `! youki run` |\|| don't touch bounding caps         |\|| success (should not! 🚨)|

# What are capabilities sets?

**Physically**, they are 5 64-bit bitmasks and each thread (not process) has a set of its own. So each thread carries 320 bits of its capabilities data.
[linux:/include/linux/cred.h#L126-L130](https://github.com/torvalds/linux/blob/6f3ed7fec72fc8979b2a8c7219c0a9fcfc8d07b5/include/linux/cred.h#L126-L130)

```c,hl_lines=,linenos,linenostart=126
kernel_cap_t	cap_inheritable; /* caps our children can inherit */
kernel_cap_t	cap_permitted;	/* caps we're permitted */
kernel_cap_t	cap_effective;	/* caps we can actually use */
kernel_cap_t	cap_bset;	/* capability bounding set */
kernel_cap_t	cap_ambient;	/* Ambient capability set */
```

**Conceptually**, they were introduced to Linux for more granular control over different privileges that historically were tightly coupled to the root user (uid=0).
Thanks to capabilities, we can, for example, give a container's root process the privilege to kill other processes **within** the same container (`CAP_KILL`) without also giving it the right to mount host's file system and escape the container environment (`CAP_SYS_ADMIN`).
This allows tools like `supervisord` [github:supervisor/supervisor](https://github.com/supervisor/supervisor) to orchestrate processes inside containers while keeping the host system safe.

**Logically**, they are sets of tokens that a thread (a task) can use to prove to the kernel that it is allowed to perform a privileged operation.
On top of that, there are rules describing how these sets affect each other and how processes pass capabilities to their children.

# What is the bounding capabilities set?

Firstly, here's the formula for the permitted set after `execve()` call: `(thread_inheritable & file_inheritable) | (file_permitted & thread_bounding_set) | thread_ambient`.

The bounding set acts as the upper hard limit for what capabilities a process can gain through the `file_permitted & thread_bounding_set` term during `execve()`. Once a capability is removed from the bounding set, no subsequent `execve()` can reintroduce it via file permitted capabilities. The one exception is the inheritable path: if the capability was already in the thread's inheritable set before the bounding set was reduced, it can still enter permitted through `thread_inheritable & file_inheritable` during `execve()`.

The ambient path `thread_ambient` won't allow the new thread/process to get the dropped capability either because Linux enforces the invariant that a cap can only be in the ambient set if it's in both permitted and inheritable. Moreover, dropping a cap from the bounding set also clears the cap from the ambient set.

# What was the bug in `youki`?

The actual bug is pretty simple to spot in the code [youki:/crates/libcontainer/src/capabilities.rs#L133-L141](https://github.com/YawKar/youki/blob/ca29917af310ae2bee4c7c866cabffc79202fcb9/crates/libcontainer/src/capabilities.rs#L133-L141):

```rust,hl_lines=7,linenos,linenostart=133
/// Drop any extra granted capabilities, and reset to defaults which are in oci specification
pub fn drop_privileges<S: Syscall + ?Sized>(
  cs: &LinuxCapabilities,
  syscall: &S,
) -> Result<(), SyscallError> {
  // 👀 When bounding is unset `youki` skipped it.
  if let Some(bounding) = cs.bounding() {
    tracing::debug!("dropping bounding capabilities to {:?}", bounding);
    syscall.set_capability(CapSet::Bounding, &to_set(bounding))?;
  }
```

The solution is clear [updated revision](https://github.com/YawKar/youki/blob/40cc9c1a0df87d4d2bc386ac0421473636d6fb01/crates/libcontainer/src/capabilities.rs#L133-L141):

```rust,hl_lines=7,linenos,linenostart=133
/// Drop any extra granted capabilities, and reset to defaults which are in oci specification
pub fn drop_privileges<S: Syscall + ?Sized>(
  cs: &LinuxCapabilities,
  syscall: &S,
) -> Result<(), SyscallError> {
  let empty_caps = Default::default();
  let bounding = cs.bounding().as_ref().unwrap_or(&empty_caps);
  tracing::debug!("dropping bounding capabilities to {:?}", bounding);
  syscall.set_capability(CapSet::Bounding, &to_set(bounding))?;
```

# What about `runc`?

They do it mostly the same, except for the ordering of user setup and capability manipulation. [runc:/libcontainer/init_linux.go#L340-L366](https://github.com/opencontainers/runc/blob/d0aeb9e3e22e02eec9f9a42416267a4f358cc571/libcontainer/init_linux.go#L340-L366)

```go,hl_lines=2-4 6-8 22-27,linenos,linenostart=340
// drop capabilities in bounding set before changing user
if err := w.ApplyBoundingSet(); err != nil {
  return fmt.Errorf("unable to apply bounding set: %w", err)
}
// preserve existing capabilities while we change users
if err := system.SetKeepCaps(); err != nil {
  return fmt.Errorf("unable to set keep caps: %w", err)
}
if err := setupUser(config); err != nil {
  return fmt.Errorf("unable to setup user: %w", err)
}
// Change working directory AFTER the user has been set up, if we haven't done it yet.
if doChdir {
  if err := unix.Chdir(config.Cwd); err != nil {
    return fmt.Errorf("chdir to cwd (%q) set in config.json failed: %w", config.Cwd, err)
  }
}
// Make sure our final working directory is inside the container.
if err := verifyCwd(); err != nil {
  return err
}
if err := system.ClearKeepCaps(); err != nil {
  return fmt.Errorf("unable to clear keep caps: %w", err)
}
if err := w.ApplyCaps(); err != nil {
  return fmt.Errorf("unable to apply caps: %w", err)
}
```

# Further reading
- [The Linux Kernel documentation: Credentials in Linux > Types of Credentials](https://docs.kernel.org/security/credentials.html#types-of-credentials)
- [Kernel Archive: Linux Capabilities FAQ 0.2](https://www.kernel.org/pub/linux/libs/security/linux-privs/kernel-2.2/capfaq-0.2.txt)
- [Kernel Archive: Linux-Privs (DRAFT v0.10 1997/4/21)](https://www.kernel.org/pub/linux/libs/security/linux-privs/old/doc/linux-privs.html/linux-privs.html)

