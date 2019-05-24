#!/bin/bash
mkdir -p secret
if [[ ! -e secret/billing.api.key ]]; then
  echo "Setting up default secret for billing.api.key"
  echo -n "12345" > secret/billing.api.key
fi

if [[ ! -e secret/billing.public.api.key ]]; then
  echo "Setting up default secret for billing.public.api.key"
  echo -n "12345" > secret/billing.public.api.key
fi

if [[ ! -e secret/iris.aes.iv ]]; then
  echo "Generating secret for iris.aes.iv"
  openssl rand -base64 8 | tr -d '\n' > secret/iris.aes.iv
fi

if [[ ! -e secret/iris.aes.secret ]]; then
  echo "Generating secret for iris.aes.secret"
  openssl rand -base64 32 | tr -d '\n' > secret/iris.aes.secret
fi

if [[ ! -e secret/questions.aes.secret ]]; then
  echo "Generating secret for questions.aes.secret"
  openssl rand -base64 32 | tr -d '\n' > secret/questions.aes.secret
fi

if [[ ! -e secret/smarty.auth.id ]]; then
  echo "Setting up default secret for smarty.auth.id"
  echo -n "12345" > secret/smarty.auth.id
fi

if [[ ! -e secret/smarty.auth.token ]]; then
  echo "Setting up default secret for smarty.auth.token"
  echo -n "12345" > secret/smarty.auth.token
fi

if [[ ! -e secret/tls.server.truststore.password ]]; then
  echo "Using *KNOWN DEFAULT* secret for tls.server.truststore.password"
  # note: the utility of truststore and keystore passwords is quesitonable.
  echo -n "8EFJhxm7aRs2hmmKwVuM9RPSwhNCtMpC" > secret/tls.server.truststore.password
fi

echo "Arcus requires a verified address. In order to verify your address, you will need to create an account on https://smartystreets.com/"
echo "Please go and create an account now, as you will be required to provide some details"
echo "Make sure to create secret keys, since these credentials will only be used on the Arcus server, and never exposed to users"

if [[ ! -e secret/smartystreets.authid ]]; then
  prompt authid "Please enter your smartystreets authid:"
  echo -n "$authid" > secret/smartystreets.authid
fi

if [[ ! -e secret/smartystreets.authtoken ]]; then
  prompt authtoken "Please enter your smartystreets authtoken:"
  echo -n "$authtoken" > secret/smartystreets.authtoken
fi

echo "Arcus requires a sendgrid API key for email notifications"

if [[ ! -e secret/email.provider.apikey ]]; then
  prompt apikey "Please enter your sendgrid API key:"
  echo -n "$apikey" > secret/email.provider.apikey
fi

echo "Arcus requires Twilio to make phone calls"

if [[ ! -e secret/twilio.account.auth ]]; then
  prompt apikey "Please enter your twilio auth:"
  echo -n "$apikey" > secret/twilio.account.auth
fi

if [[ ! -e secret/twilio.account.sid ]]; then
  prompt apikey "Please enter your twilio sid:"
  echo -n "$apikey" > secret/twilio.account.sid
fi

if [[ ! -e secret/twilio.account.from ]]; then
  prompt apikey "Please enter your twilio phone number:"
  echo -n "$apikey" > secret/twilio.account.from
fi

set +e
$KUBECTL create secret generic shared --from-file secret/
set -e

