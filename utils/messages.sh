#!/usr/bin/env bash
#

LANGS="zh_CN en zh_Hant"

function init_message() {
    find . -iname "*.sh" | xargs  xgettext --output=/tmp/jumpserver-installer.pot --from-code=UTF-8

    for lang in $LANGS; do
        mkdir -p locale/${lang}/LC_MESSAGES
        msginit --input=/tmp/jumpserver-installer.pot --locale=locale/${lang}/LC_MESSAGES/jumpserver-installer.po
    done
}

function make_message() {
    find . -iname "*.sh" | xargs  xgettext --output=/tmp/jumpserver-installer.pot --from-code=UTF-8

    for lang in $LANGS; do
        msginit --input=/tmp/jumpserver-installer.pot --locale=locale/${lang}/LC_MESSAGES/jumpserver-installer-tmp.po
        msgmerge -U locale/${lang}/LC_MESSAGES/jumpserver-installer-tmp.po /tmp/jumpserver-installer.pot
    done

    for lang in $LANGS; do
        rm -f locale/${lang}/LC_MESSAGES/jumpserver-installer-tmp.po
        rm -f locale/${lang}/LC_MESSAGES/jumpserver-installer.po\~
    done
}

function compile_message() {
    for lang in $LANGS; do
        msgfmt --output-file=locale/${lang}/LC_MESSAGES/jumpserver-installer.mo locale/${lang}/LC_MESSAGES/jumpserver-installer.po
    done
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
