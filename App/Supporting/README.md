# Supporting

`Info.plist` is generated here by `xcodegen generate` from the `info:` block in
[`../project.yml`](../project.yml). Edit the spec, not the plist: the file is
overwritten on every regeneration.

It lives outside `Sources/ssshApp` on purpose. That directory is the target's
source path, and a plist inside it would be picked up as a resource as well as
being the target's `INFOPLIST_FILE`, putting it in the bundle twice.
