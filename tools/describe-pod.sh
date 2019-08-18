#!/bin/bash

$KUBECTL describe pod -l app=$1
