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

To synchronize with a remote location, the `psync` script needs to be in the path 
on the remote system. The name of the script has to be the same as the one used to initiate the 
sync. I recommend only using SSH Public Key authentication to
avoid any password interactions. Make sure authentication between the remote systems works
properly before using `psync`.


Multidirectional sync
======================
Using the `--tag` option it is possible to synchronize the same root to a multitude of other roots
in any way you desire. You just have to specify a unique `tagname` for each unique
pair of roots (leg). Using the same `tagname` on different legs will result in unexpected
syncronization problems.


Metadata
========
Metadata that is needed to sync properly is stored in the `.psync` folder in each
root. When using the `--tag` option, additional metadata will be stored for each leg
in the same `.psync` folder.


Examples
========
Just synchronize two roots on localhost

    psync /home/user/root1 /home/user/root2

Synchronize a local root with a remote root

    psync /home/user/root1 user@remote:/home/user/root

Synchronize two remote roots

    psync user@remote:/home/user/root1 user@remote:/home/user/root2

Three-way sync

    psync --tag leg1 /home/user/root user@remote:/home/user/root1
    psync --tag leg2 /home/user/root user@remote:/home/user/root2


Design Guidelines
=================
This script was developed with the following ideas in mind, please maintain those ideas
when submitting pull-requests.

* The script should be a single file so it can be copied to other systems easily.
* The module dependencies should be kept low, only core and a few non-exotic modules are used.
* It should work with most Perl versions commonly in use


TODO and Known issues
=====================
* Only works on *NIX (only tested on OS X)
* Empty directories and deleted directories are not syncronized. Directories are only created when needed to copy a file.
* Timestamps are not preserved or synchronized
* Possibly implement better multidirectional sync
* Improve code documentation
* Conflicts (simultaneous changes in both roots) are not handled by the script. They are just displayed to be handled manually directly on the filesystem.
* Eventhough `psync` is reasonably fast, it was not built for speed or efficiency rather it was made to be simple and reliable.
