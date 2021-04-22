#!/bin/bash
#

function init_message() {
    find . -iname "*.sh" | xargs  xgettext --output=/tmp/jumpserver-installer.pot --from-code=UTF-8

    msginit --input=/tmp/jumpserver-installer.pot --locale=locale/zh_CN/LC_MESSAGES/jumpserver-installer.po

    msginit --input=/tmp/jumpserver-installer.pot --locale=locale/en/LC_MESSAGES/jumpserver-installer.po
}

function make_message() {

    find . -iname "*.sh" | xargs  xgettext --output=/tmp/jumpserver-installer.pot --from-code=UTF-8

    msginit --input=/tmp/jumpserver-installer.pot --locale=locale/zh_CN/LC_MESSAGES/jumpserver-installer-tmp.po
    msgmerge -U locale/zh_CN/LC_MESSAGES/jumpserver-installer.po locale/zh_CN/LC_MESSAGES/jumpserver-installer-tmp.po

    msginit --input=/tmp/jumpserver-installer.pot --locale=locale/en/LC_MESSAGES/jumpserver-installer-tmp.po
    msgmerge -U locale/en/LC_MESSAGES/jumpserver-installer.po locale/en/LC_MESSAGES/jumpserver-installer-tmp.po

    rm ./locale/zh_CN/LC_MESSAGES/jumpserver-installer-tmp.po
    rm ./locale/en/LC_MESSAGES/jumpserver-installer-tmp.po
}

function compile_message() {
   msgfmt --output-file=locale/zh_CN/LC_MESSAGES/jumpserver-installer.mo locale/zh_CN/LC_MESSAGES/jumpserver-installer.po

   msgfmt --output-file=locale/en/LC_MESSAGES/jumpserver-installer.mo locale/en/LC_MESSAGES/jumpserver-installer.po
}

action=$1
if [ -z "$action" ]; then
    action="make"
fi

case $action in
    m|make)
        make_message;;
    i|init)
        init_message;;
    c|compile)
        compile_message;;
    *)
        echo "Usage: $0 [m|make i|init | c|compile]"
        exit 1
        ;;
esac
