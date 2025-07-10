#!/bin/bash

# Add Static Route to TGW Route Table

read -p "Enter Transit Gateway route table ID: " ROUTE_TABLE_ID
read -p "Enter Destination CIDR Block: " CIDR
read -p "Enter Transit Gateway Attachment ID: " ATT_ID
read -p "Enter AWS CLI Profile name: " AWS_PROFILE

aws --profile "$AWS_PROFILE" ec2 create-transit-gateway-route --transit-gateway-route-table-id "$ROUTE_TABLE_ID" --destination-cidr-block "$CIDR" --transit-gateway-attachment-id "$ATT_ID" --profile legacy-Shared


echo "Static route created (CIDR: $CIDR -> Attachement: $ATT_ID)"