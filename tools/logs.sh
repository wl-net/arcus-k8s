#!/bin/bash

$KUBECTL logs --tail=10000 -l app=$1 -c $1
