#!/bin/bash

PORT_TO_START_WITH=1025

if ! [ "$1" == "" ]; then
  re='^[1-9][0-9]*$'
  
  # not a valid number
  if ! [[ $1 =~ $re ]] ; then
	  NUM_OF_PORTS_TO_PROVIDE=1
  else
    NUM_OF_PORTS_TO_PROVIDE=$1
  fi
else
  NUM_OF_PORTS_TO_PROVIDE=1
fi


CURRENT_NON_SYSTEM_USED_PORTS=$(ss -ptuln | grep LISTEN | awk '{print $5}' | cut -d':' -f2 | sort -nu | tr '\n' ' ')


while [ $NUM_OF_PORTS_TO_PROVIDE -gt 0 ]; do
  if ! [[ " $CURRENT_NON_SYSTEM_USED_PORTS " == *" $PORT_TO_START_WITH "* ]]; then
    OUTPUT_PORTS=$PORT_TO_START_WITH" "$OUTPUT_PORTS
    
    NUM_OF_PORTS_TO_PROVIDE=$((NUM_OF_PORTS_TO_PROVIDE - 1))
  fi
  
  PORT_TO_START_WITH=$((PORT_TO_START_WITH + 1))
done


echo $OUTPUT_PORTS


