#!/bin/bash

$KUBECTL delete pod -l app=$1
