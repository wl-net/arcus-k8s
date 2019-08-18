#!/bin/bash

$KUBECTL logs -l app=$1 -c $1
