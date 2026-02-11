.PHONY: build start stop test restart clean

build:
cd skynet && make linux

start:
./start.sh

stop:
./stop.sh

test:
lua test/test_client.lua

restart: stop
@sleep 1
@./start.sh

clean:
rm -f skynet.pid
