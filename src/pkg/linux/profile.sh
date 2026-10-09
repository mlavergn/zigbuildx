# Installed by the {pkg_name} package: puts its programs on PATH.
case ":$PATH:" in
*":/usr/local/{pkg_org}/{pkg_name}/bin:"*) ;;
*) PATH="$PATH:/usr/local/{pkg_org}/{pkg_name}/bin" ;;
esac
