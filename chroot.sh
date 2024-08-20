#!/bin/bash
 
DIR=/mnt/
 
mkdir -p $DIR
 
for i in bin run dev proc sys 
do
  mkdir $DIR/$i
  mount -o bind /$i $DIR/$i
done
 
chroot $DIR
