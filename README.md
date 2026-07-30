java-install
============

Install Java for LF Jenkins infra.

Requirements
------------

None.

Role Variables
--------------

:java_sdkman_install: Install the JVM toolchain (JDKs, Maven and mvnd) with
    SDKMAN! in addition to the distribution packages. Versions resolve from
    the SDKMAN! broker API when the image is built, so the toolchain is not
    tied to a distribution release. Adds roughly 2GB to the image.
    (default: ``false``)
:java_sdkman_dir: Directory SDKMAN! installs into. (default: ``/opt/sdkman``)

The distribution JDK stays the system default. Jenkins jobs opt in to a
SDKMAN! JDK per job by setting ``JDK_PROVIDER=sdkman``.

Dependencies
------------

None.

Example Playbook
----------------

    - hosts: servers
      roles:
         - { role: java-install }

License
-------

MIT

Author Information
------------------

Linux Foundation Release Engineering
