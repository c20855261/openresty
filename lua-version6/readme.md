###
#101.78.213.50 qa ben ip
#223.73.3.209 qa susie
#223.73.3.230 susie

sample

for i in {1..10}; do curl -s -X GET "http://h5.smwl99.com/testfake.html" -w "Test $i: %{http_code}\n" -o /dev/null; sleep 0.1; done


