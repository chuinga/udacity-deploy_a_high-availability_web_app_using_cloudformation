#!/bin/sh

# Initialize the profile variable
profile=""

# Parse only --profile
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { echo "Error: Argument for $1 is missing" >&2; exit 1; }
      case "$2" in -*) echo "Error: Argument for $1 is missing" >&2; exit 1;; esac
      profile="$2"; shift 2;;
    *) echo "Error: Unsupported flag $1" >&2; exit 1;;
  esac
done

aws cloudformation update-stack \
  --stack-name networkserver \
  --template-body file://network.yml \
  --parameters file://network-parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  ${profile:+--profile "$profile"} || {
  echo "Error: CloudFormation stack update failed" >&2
  exit 1
}
