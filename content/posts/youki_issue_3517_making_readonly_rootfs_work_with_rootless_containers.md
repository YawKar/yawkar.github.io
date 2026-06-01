+++
title = "[youki] Fixing readonly rootfs in rootless containers when NODEV/NOEXEC/NOSUID are set"
date = 2026-05-18
[taxonomies]
tags= ["youki", "rust", "containers", "linux"]
+++

> - issue: [#3517:[root.readonly: true] does not work on filesystems mounted with nodev or nosuid in usernamespace](https://github.com/youki-dev/youki/issues/3517)
> - fix: [#3536:preserve mount flags for readonly remount of rootfs in init](https://github.com/youki-dev/youki/pull/3536)

# TL;DR
- `youki` forgot about original mount flags of the filesystem it was trying to remount
- in <abbr title="i.e. containers that require a new user namespace to be created for them">rootless containers</abbr> Linux [locks](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L2412-L2437) some of [these mount flags](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/include/linux/mount.h#L39-L43) down for security reasons
- when Linux sees that `youki`'s init process tries to remount rootfs and drop locked flags it [throws `EPERM`](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L3343-L3344)
- solution is to include the original mount flags to the remount call

# How <u>did</u> youki handle `root.readonly: true`?
[youki:crates/libcontainer/src/process/init/process.rs#L199-L213](https://github.com/youki-dev/youki/blob/aab4d42f8c8b6e26bc37e224b44f9c566d8e7a68/crates/libcontainer/src/process/init/process.rs#L199-L213):

```rust,hl_lines=10,linenos,linenostart=199
if matches!(args.container_type, ContainerType::InitContainer) {
  if ctx.rootfs_ro {
    ctx.syscall
      .mount(
        None,
        Path::new("/"),
        None,
        // 👀 Notice how it didn't bother about
        // 👀 any of the original mount flags
        MsFlags::MS_RDONLY | MsFlags::MS_REMOUNT | MsFlags::MS_BIND,
        None,
      )
      .map_err(|err| {
        tracing::error!(?err, "failed to remount root `/` as readonly");
        InitProcessError::SyscallOther(err)
      })?;
  }
```

This works perfectly for rootful containers run by a user with the `CAP_SYS_ADMIN` capability (`youki` resets effective and drops capabilities a little bit [later in the flow](https://github.com/youki-dev/youki/blob/64ebe829ccd0e4bb92e7eb750854ab38d1bbc111/crates/libcontainer/src/process/init/process.rs#L372-L381)).

But for **rootless** containers, a new user namespace is always created and Linux locks some of the mount flags in this case.
It makes sense because we generally don't want a subordinate user namespace to be able to drop our security restrictions.

When these flags are locked, an attempt to remount without these flags gets `EPERM` from the kernel.

[linux:/fs/namespace.c#L3326-L3344](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L3326-L3344):
```c,hl_lines=19-20,linenos,linenostart=3326
/*
 * Handle reconfiguration of the mountpoint only without alteration of the
 * superblock it refers to.  This is triggered by specifying MS_REMOUNT|MS_BIND
 * to mount(2).
 */
static int do_reconfigure_mnt(const struct path *path, unsigned int mnt_flags)
{
  struct super_block *sb = path->mnt->mnt_sb;
  struct mount *mnt = real_mount(path->mnt);
  int ret;

  if (!check_mnt(mnt))
    return -EINVAL;

  if (!path_mounted(path))
    return -EINVAL;

  // 👀
  if (!can_change_locked_flags(mnt, mnt_flags))
    return -EPERM;
```

[linux:/fs/namespace.c#L3242-L3273](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L3242-L3273)
```c,hl_lines=,linenos,linenostart=3242
/*
 * Don't allow locked mount flags to be cleared.
 *
 * No locks need to be held here while testing the various MNT_LOCK
 * flags because those flags can never be cleared once they are set.
 */
static bool can_change_locked_flags(struct mount *mnt, unsigned int mnt_flags)
{
	unsigned int fl = mnt->mnt.mnt_flags;

	if ((fl & MNT_LOCK_READONLY) &&
	  !(mnt_flags & MNT_READONLY))
		return false;

	if ((fl & MNT_LOCK_NODEV) &&
	  !(mnt_flags & MNT_NODEV))
		return false;

	if ((fl & MNT_LOCK_NOSUID) &&
	  !(mnt_flags & MNT_NOSUID))
		return false;

	if ((fl & MNT_LOCK_NOEXEC) &&
	  !(mnt_flags & MNT_NOEXEC))
		return false;

	if ((fl & MNT_LOCK_ATIME) &&
	  ((fl & MNT_ATIME_MASK) != (mnt_flags & MNT_ATIME_MASK)))
		return false;

	return true;
}
```

[linux:/fs/namespace.c#L2412-L2437](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L2412-L2437):
```c,hl_lines=,linenos,linenostart=2412
static void lock_mnt_tree(struct mount *mnt)
{
  struct mount *p;

  for (p = mnt; p; p = next_mnt(p, mnt)) {
    int flags = p->mnt.mnt_flags;
    /* Don't allow unprivileged users to change mount flags */
    flags |= MNT_LOCK_ATIME;

    if (flags & MNT_READONLY)
      flags |= MNT_LOCK_READONLY;

    if (flags & MNT_NODEV)
      flags |= MNT_LOCK_NODEV;

    if (flags & MNT_NOSUID)
      flags |= MNT_LOCK_NOSUID;

    if (flags & MNT_NOEXEC)
      flags |= MNT_LOCK_NOEXEC;
    /* Don't allow unprivileged users to reveal what is under a mount */
    if (list_empty(&p->mnt_expire) && p != mnt)
      flags |= MNT_LOCKED;
    p->mnt.mnt_flags = flags;
  }
}
```

Usage examples show us that the lock is placed when a mount is cloned across a user namespace boundary:

- [linux:/fs/namespace.c#L2637-L2639](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L2637-L2639)
  ```c,hl_lines=,linenos,linenostart=2637
  /* Notice when we are propagating across user namespaces */
  if (child->mnt_parent->mnt_ns->user_ns != user_ns)
    lock_mnt_tree(child);
  ```
- [linux:/fs/namespace.c#L3156-L3162](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L3156-L3162)
  ```c,hl_lines=,linenos,linenostart=3156
  /*
   * now mount the detached tree on top of the copy
   * of the real rootfs we created.
   */
  attach_mnt(mnt, new_ns_root, mp.mp);
  if (user_ns != ns->user_ns)
    lock_mnt_tree(new_ns_root);
  ```
- [linux:/fs/namespace.c#L4266-L4270](https://github.com/torvalds/linux/blob/1bfaee9d3351b9b32a99766bbfb1f5baed60ddef/fs/namespace.c#L4266-L4270)
  ```c,hl_lines=,linenos,linenostart=4266
  if (user_ns != ns->user_ns) {
    guard(mount_writer)();
    lock_mnt_tree(new);
  }
  new_ns->root = new;
  ```

# How <u>does</u> youki handle `root.readonly: true` after fix?
[youki:crates/libcontainer/src/process/init/process.rs#L201-L225](https://github.com/youki-dev/youki/blob/64ebe829ccd0e4bb92e7eb750854ab38d1bbc111/crates/libcontainer/src/process/init/process.rs#L201-L225):

```rust,hl_lines=4-10 20,linenos,linenostart=201
if matches!(args.container_type, ContainerType::InitContainer) {
  if ctx.rootfs_ro {
    // 👀 Here we get the original mount flags ...
    let current_flags = statfs("/")
      .map_err(|err| {
        tracing::error!(?err, "failed to statfs root '/' to get current mount flags");
        InitProcessError::SyscallOther(SyscallError::Nix(err))
      })?
      .flags()
      .bits();
    ctx.syscall
      .mount(
        None,
        Path::new("/"),
        None,
        MsFlags::MS_RDONLY
          | MsFlags::MS_REMOUNT
          | MsFlags::MS_BIND
          // 👀 ... and here we reuse them!
          | MsFlags::from_bits_truncate(current_flags),
        None,
      )
      .map_err(|err| {
        tracing::error!(?err, "failed to remount root `/` as readonly");
        InitProcessError::SyscallOther(err)
      })?;
  }
```

# A note on `youki`'s testing infrastructure

`youki` has a really nice testing framework called `contest`.
It makes it very easy to set up fixtures and hook into a container before the init process enters it.


It also allows hooking inside the container using `runtimetest` static binary which is compiled with a set
of validators which are just simple functions that execute some checks and may output something into `stderr`
which indicates a validation failure.

[youki:/tests/contest/contest/src/tests/root_readonly_true/root_readonly_tests.rs#L31-L63](https://github.com/YawKar/youki/blob/e4b4896c6dbfd28270e11beb73e4799d7317556c/tests/contest/contest/src/tests/root_readonly_true/root_readonly_tests.rs#L31-L63):

```rust,hl_lines=,linenos,linenostart=31
fn root_readonly_true_in_userns_test() -> TestResult {
  // 👀 Here we get the effective user under which the test-runner itself is running.
  // 👀 We need it to safely map the user inside the new container's user namespace to our user.
  let uid = nix::unistd::geteuid().as_raw();
  let gid = nix::unistd::getegid().as_raw();
  let mut spec = Spec::rootless(uid, gid);
  // 👀 Set readonly to `true`
  spec.set_root(RootBuilder::default().readonly(true).build().ok())
    .set_process(
      ProcessBuilder::default()
        // 👀 Here I use `root_readonly` validator that is already made by someone else:
        // 👀 https://github.com/YawKar/youki/blob/e4b4896c6dbfd28270e11beb73e4799d7317556c/tests/contest/runtimetest/src/main.rs#L50
        .args(vec!["runtimetest".to_string(), "root_readonly".to_string()])
        .build()
        .ok(),
    );
  test_inside_container(&spec, &CreateOptions::default(), &|rootfs: &Path| {
    // Bind-mount the rootfs onto itself with MS_NODEV | MS_NOSUID, simulating a
    // filesystem that has those flags locked (the typical case in user namespaces).
    // Without the fix for #3517, the subsequent readonly remount would fail with
    // EPERM because the kernel rejects dropping these flags in a user namespace.
    // 👀 Here's why we need 2 mount calls:
    // 👀 Initially '/' is just a directory inside the container namespace.
    // 👀 Linux doesn't allow mount() calls on directories.
    // 👀 We need to MS_BIND '/' to make a mount point out of it.
    nix::mount::mount(
      Some(rootfs),
      rootfs,
      None::<&str>,
      MsFlags::MS_BIND,
      None::<&str>,
    )?;
    // 👀 Now that we have a mount point we are free to modify mount flags!
    nix::mount::mount(
      Some(rootfs),
      rootfs,
      None::<&str>,
      MsFlags::MS_REMOUNT | MsFlags::MS_BIND | MsFlags::MS_NODEV | MsFlags::MS_NOSUID,
      None::<&str>,
    )?;
    Ok(())
  })
}
```

You can read more about it here: [Youki Developer docs: Contest](https://youki-dev.github.io/youki/developer/e2e/rust_oci_test.html).
