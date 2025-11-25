#!/bin/bash

#docker exec redis redis-cli --raw KEYS 'count:*' | xargs -n1 -I{} sh -c 'echo -n "{}: "; docker exec redis redis-cli GET {}'

docker exec redis redis-cli --raw KEYS '*:*' | xargs -n1 -I{} sh -c 'echo -n "{}: "; docker exec redis redis-cli GET {}'
