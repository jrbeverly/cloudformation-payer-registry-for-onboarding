#!/bin/sh
# Usage: ./generate-onboarding-stack.sh <request-id> <central-account-id>
set -eu

REQUEST_ID=$1
CENTRAL_ACCOUNT_ID=$2
DIR=$(dirname "$0")
REGISTRATION_BUCKET="onboarding-registration-$CENTRAL_ACCOUNT_ID"
REGISTRATION_ENDPOINT=$(aws s3 presign "s3://$REGISTRATION_BUCKET/registrations/$REQUEST_ID.json" --expires-in 604800)
ZIP_FILE=$(jq -Rs . "$DIR/registration-function.js")

mkdir -p "$DIR/requests"
jq -n --arg requestId "$REQUEST_ID" --arg centralAccountId "$CENTRAL_ACCOUNT_ID" \
  '{requestId: $requestId, centralAccountId: $centralAccountId}' > "$DIR/requests/$REQUEST_ID.json"

cat <<EOF
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Onboarding bootstrap stack",
  "Parameters": {
    "OnboardingRequestId": {
      "Type": "String",
      "Default": "$REQUEST_ID"
    },
    "CentralAccountId": {
      "Type": "String",
      "Default": "$CENTRAL_ACCOUNT_ID"
    },
    "RegistrationEndpoint": {
      "Type": "String",
      "Default": "$REGISTRATION_ENDPOINT"
    }
  },
  "Resources": {
    "BootstrapRole": {
      "Type": "AWS::IAM::Role",
      "Properties": {
        "AssumeRolePolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "AWS": {
                  "Fn::Sub": "arn:aws:iam::\${CentralAccountId}:root"
                }
              },
              "Action": "sts:AssumeRole"
            }
          ]
        },
        "Policies": [
          {
            "PolicyName": "OrganizationDiscovery",
            "PolicyDocument": {
              "Version": "2012-10-17",
              "Statement": [
                {
                  "Effect": "Allow",
                  "Action": [
                    "organizations:DescribeOrganization",
                    "organizations:ListRoots",
                    "organizations:ListChildren",
                    "organizations:ListOrganizationalUnitsForParent",
                    "organizations:ListAccounts"
                  ],
                  "Resource": "*"
                }
              ]
            }
          },
          {
            "PolicyName": "NextStageRoleDeployment",
            "PolicyDocument": {
              "Version": "2012-10-17",
              "Statement": [
                {
                  "Effect": "Allow",
                  "Action": [
                    "iam:CreateRole",
                    "iam:PutRolePolicy"
                  ],
                  "Resource": {
                    "Fn::Sub": "arn:aws:iam::\${AWS::AccountId}:role/onboarding/*"
                  }
                }
              ]
            }
          }
        ]
      }
    },
    "RegistrationFunctionRole": {
      "Type": "AWS::IAM::Role",
      "Properties": {
        "AssumeRolePolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "Service": "lambda.amazonaws.com"
              },
              "Action": "sts:AssumeRole"
            }
          ]
        },
        "Policies": [
          {
            "PolicyName": "RegistrationExecution",
            "PolicyDocument": {
              "Version": "2012-10-17",
              "Statement": [
                {
                  "Effect": "Allow",
                  "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents"
                  ],
                  "Resource": "arn:aws:logs:*:*:*"
                },
                {
                  "Effect": "Allow",
                  "Action": "organizations:DescribeOrganization",
                  "Resource": "*"
                }
              ]
            }
          }
        ]
      }
    },
    "RegistrationFunction": {
      "Type": "AWS::Lambda::Function",
      "Properties": {
        "Runtime": "nodejs22.x",
        "Handler": "index.handler",
        "Role": {
          "Fn::GetAtt": [
            "RegistrationFunctionRole",
            "Arn"
          ]
        },
        "Timeout": 30,
        "Code": {
          "ZipFile": $ZIP_FILE
        }
      }
    },
    "RegistrationInvokePermission": {
      "Type": "AWS::Lambda::Permission",
      "Properties": {
        "FunctionName": {
          "Ref": "RegistrationFunction"
        },
        "Action": "lambda:InvokeFunction",
        "Principal": "cloudformation.amazonaws.com"
      }
    },
    "Registration": {
      "Type": "Custom::Registration",
      "Properties": {
        "ServiceToken": {
          "Fn::GetAtt": [
            "RegistrationFunction",
            "Arn"
          ]
        },
        "Endpoint": {
          "Ref": "RegistrationEndpoint"
        },
        "RequestId": {
          "Ref": "OnboardingRequestId"
        },
        "AccountId": {
          "Ref": "AWS::AccountId"
        },
        "BootstrapRoleArn": {
          "Fn::GetAtt": [
            "BootstrapRole",
            "Arn"
          ]
        },
        "Region": {
          "Ref": "AWS::Region"
        }
      }
    }
  },
  "Outputs": {
    "BootstrapRoleArn": {
      "Value": {
        "Fn::GetAtt": [
          "BootstrapRole",
          "Arn"
        ]
      }
    }
  }
}
EOF
