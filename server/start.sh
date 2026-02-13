#!/bin/bash
MY_PATH=$(cd `dirname $0`; pwd)
cd "$MY_PATH"

dir=`dirname $0`
cd $dir
url=`pwd`
cd $url


mkdir -p log_game
../runtime/skynet skynet_config