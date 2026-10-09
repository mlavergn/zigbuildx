#!/bin/bash

sudo rm /etc/paths.d/{pkg_name}
sudo rm -r /usr/local/{pkg_org}/{pkg_name}
sudo rm -r /etc/{pkg_org}/{pkg_name}
sudo pkgutil --forget {pkg_id}
