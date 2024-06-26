#!/bin/bash
cd react/admin && yarn install
mkdir -p docs
./node_modules/.bin/react-docgen . -o rdout.json
while read KEY ; do
    [ -z "${KEY}" ] && continue
    while read PROP ; do
        CONTENT=$(jq -r ".[\"${KEY}\"][\"${PROP}\"]" rdout.json)
        case $PROP in
            "description")
                DESCRIPTION=$CONTENT
                ;;
            "displayName")
                NAME=$CONTENT
                FILE="docs/${NAME}.md"
                ;;
            "methods")
                METHODS=$CONTENT
                ;;
            "props")
                PROPS=$CONTENT
                ;;
        esac
    done <<< "$(jq -r ".[\"${KEY}\"] | keys[]" rdout.json)"
    echo "# Cabalmail" >$FILE
    echo '<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />' >>$FILE
    echo '<p><a href="/README.md">Main documentation</a></p>' >>$FILE
    echo '</div><div style="padding-left: 11em;">' >>$FILE
    echo "# ${NAME}" >>$FILE
    echo $DESCRIPTION >>$FILE
    echo >>$FILE
    # echo "## Props" >>$FILE
    # echo $PROPS | jq -c "keys" | while read PROP ; do
    #     PBODY=$(echo $PROP | jq -r ".${PROP}")
    #     echo $PROP
    #     echo $PBODY
    # done
    # echo >>$FILE
    echo "## Methods" >>$FILE
    echo $METHODS | jq -c ".[]" | while read METHOD ; do
        MNAME=$(echo $METHOD | jq -r ".name")
        MMODIFIERS=$(echo $METHOD | jq -r ".modifiers[]")
        MPARAMS="$(echo $METHOD | jq -r ".params[].name") ($(echo $METHOD | jq -r ".params[].type"))"
        MRETURNS=$(echo $METHOD | jq -r ".returns")
        echo "### $MNAME" >>$FILE
        echo "Modifiers: ${MMODIFIERS:-none}" >>$FILE
        echo >>$FILE
        echo "Parameters: ${MPARAMS}" >>$FILE
        echo >>$FILE
        echo "Returns: ${MRETURNS}" >>$FILE
        echo >>$FILE
    done
    echo "</div>" >>$FILE
done <<< "$(jq -r 'keys[]' rdout.json)"
rm rdout.json