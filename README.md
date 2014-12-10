psync
=====

Bidirectional File Synchronizer written in Perl.


Usage
=====

```
psync [-dv] [options] <root_1> <root_2>
    -v --verbose     Verbose
    -d --debug       Debug output
    --tag <tagname>  Metadata Tag
```

Two roots are required, all options are optional.

Simply specify two roots that you need to synchronize. A root can be
on the local filesystem e.g. `/home/user/path` or remote over ssh e.g. `user@host:/path`


Remote Syncronization
=====================
To synchronize with a remote location, the `psync` script needs to be in the path 
on the remote system. The name of the script must be the same as the one used to initiate the 
sync.

Keep in mind that when the `psync` script is updated, the remote script also needs to be updated.

I recommend only using SSH Public Key Authentication to
avoid any password interactions. Make sure SSH authentication between the systems works
properly before using `psync`.


Multidirectional sync
======================
Using the `--tag` option it is possible to synchronize the same root to a multitude of other roots
in any way you desire. You just have to specify a unique `tagname` for each unique
pair of roots (leg). Not specifying a `tagname` or using the same `tagname` on different legs 
will result in unexpected syncronization problems.


Metadata
========
Metadata that is needed to sync properly is stored in the `.psync` folder in each
root. 

When using the `--tag` option, additional metadata will be stored for each leg
in the same `.psync` folder.

Keep in mind that the metadata of both roots of a leg have to remain in sync. Normally this
will be the case so you don't need to worry about that. But when one of the roots is replaced
by an older backup, the metadata becomes out of sync. This can result in some
unexpected behavior including possible loss of some data. One way around this problem
is to start using a new `tagname` after the leg became out of sync.
This will cause both roots to be merged and no data will be lost (conflicts may occur though).
If you expect only small differences between the two roots you can simply use the same `tagname`
(or no `tagname`) as before, monitor the changes and make manual changes if needed. Make sure
you make a backup of both roots before syncing.


Examples
========
Just synchronize two roots on localhost

    psync /home/user/root1 /home/user/root2

Synchronize a local root with a remote root

    psync /home/user/root user@remote:/home/user/root

Synchronize two remote roots

    psync user@remote1:/home/user/root user@remote2:/home/user/root

Three-way sync

    psync --tag leg1 /home/user/root user@remote1:/home/user/root
    psync --tag leg2 /home/user/root user@remote2:/home/user/root


Design Guidelines
=================
This script was developed with the following ideas in mind, please maintain those ideas
when submitting pull-requests.

* The script should be a single file so it can be copied to other systems easily.
* The module dependencies should be kept low, only core and a few non-exotic modules are used.
* It should work with most Perl versions commonly in use (currently v5.10 is required)


TODO and Known issues
=====================
* Only works on *NIX (only tested on OS X)
* Empty directories and deleted directories are not syncronized. Directories are only created when needed to copy a file.
* Timestamps are not preserved or synchronized
* Possibly implement better multidirectional sync, probably as a separate script
* Improve code documentation
* Conflicts (simultaneous changes in both roots) are not handled by the script. They are just displayed to be handled manually directly on the filesystem.
* Eventhough `psync` is reasonably fast, it was not built for speed or efficiency rather it was made to be simple and reliable.
* Remove more module dependencies.
* Build in check to ensure local and remote `psync` scripts are compatible.
* Improve readability of the script output.
* A temp file (in the format .<filename>.<number>) could be left behind under certain situations, probably when psync is interrupted during a transfer.
