module "cors" {
  source          = "squidfunk/api-gateway-enable-cors/aws"
  version         = "0.3.3"

  api_id          = var.gateway_id
  api_resource_id = aws_api_gateway_resource.api_call.id
  allow_headers   = [
    "Authorization",
    "Content-Type",
    "X-Amz-Date",
    "X-Amz-Security-Token",
    "X-Api-Key",
    "origin",
    "Referer",
    "User-Agent",
    "X-Requested-With"
  ]
}
# CORS Safe: Accept Accept-Language Content-Language Content-Type
# Sent according to Chrome:
    # accept: application/json, text/plain, */*
    # accept-encoding: gzip, deflate, br
    # accept-language: en-US,en;q=0.9
    # authorization: eyJraWQiOiJqeUxMTThVc1gzYndWRTdVRnBhc3Faa1U1dGh2U1wvYk5CQktuRUpZMFB5az0iLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIwN2MwMzhjNS1jZTI5LTRiMDUtODYxNy04MDYzNzE2YWZkNGYiLCJpc3MiOiJodHRwczpcL1wvY29nbml0by1pZHAudXMtZWFzdC0xLmFtYXpvbmF3cy5jb21cL3VzLWVhc3QtMV81STNjUU5hSVciLCJwaG9uZV9udW1iZXJfdmVyaWZpZWQiOmZhbHNlLCJjb2duaXRvOnVzZXJuYW1lIjoiY2hyaXMiLCJwcmVmZXJyZWRfdXNlcm5hbWUiOiJjaHJpcyIsIm9yaWdpbl9qdGkiOiI1MjY5MzRiNi0zM2RmLTRmOTItOTVkNy0wYTFkYzkyN2QzY2EiLCJhdWQiOiI0NmcxcDBidTJ0amgzcmpjNm51YXNwZDc2MyIsImV2ZW50X2lkIjoiNjVmNTMwZTAtODc2Yy00MzExLWJlYWMtZGFiMjdhM2Y1YTFkIiwidG9rZW5fdXNlIjoiaWQiLCJhdXRoX3RpbWUiOjE2NjY1MzE5MjMsInBob25lX251bWJlciI6Iis2MDM4MzExNzg2IiwiZXhwIjoxNjY2NTM1NTIzLCJpYXQiOjE2NjY1MzE5MjMsImp0aSI6ImVjNjU5YzI3LTRhNzgtNDhjYS04YTljLTViZTBjYmIwZjc4OCJ9.kGFmWDW0X6yCRIRefvm4qH3cOuSN9zQqdUVnefU8eyjpyBpQMxtSdrv54ejhQDJ53wYGxtTcYZJVHNIJQ1PabJ6hIfqs9hyXnDiUSrZMKsiC8gU27lgu1dRQsCyjVaf2ovhb0WSN0SZPONfBMWMlmBLXPEe0Zs6rEsNioN6kgtdtfArfWNRFW0aA3kI12d6eBkKOoZyGNmXYrbmcikqva2IBM-Q-4Fwy-eafa4FsPPAros2PYO-GBXT_qXfIn1IscC5HNNeLYOqv5yVuFEwX57fDKTd0YItPuQ99xe0lTvzj6_cAxkG-g6-kcVxesapgly8KLgCVeb8KC3q9-ZT1JQ
    # content-length: 49
    # content-type: application/x-www-form-urlencoded
    # origin: https://admin.cabal-mail.net
    # referer: https://admin.cabal-mail.net/
    # sec-ch-ua: "Chromium";v="106", "Google Chrome";v="106", "Not;A=Brand";v="99"
    # sec-ch-ua-mobile: ?0
    # sec-ch-ua-platform: "macOS"
    # sec-fetch-dest: empty
    # sec-fetch-mode: cors
    # sec-fetch-site: cross-site
    # user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36
