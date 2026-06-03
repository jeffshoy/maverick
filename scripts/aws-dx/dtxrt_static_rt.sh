#!/bin/bash

# This script searches a given Transit Gateway route table for propagated routes originating from a specified resource ID and Replace them by static route

read -p "Enter the Transit Gateway Route Table ID: " ROUTE_TABLE_ID
read -p "Enter the resource ID to search in routes: " RESOURCE_ID
read -p "Enter AWS CLI Profile name: " AWS_PROFILE

  #Searching route table propagated routes from resource: $RESOURCE_ID

  ROUTES=$(aws --profile "$AWS_PROFILE" ec2 search-transit-gateway-routes \
    --transit-gateway-route-table-id "$ROUTE_TABLE_ID" \
    --filters Name=type,Values=propagated Name=attachment.resource-id,Values="$RESOURCE_ID" \
    --query 'Routes[*].[DestinationCidrBlock,TransitGatewayAttachments[0].TransitGatewayAttachmentId]' \
    --output text)
          
if [[ -n "$ROUTES" ]]; then  
    echo "Found routes:"
    while IFS=$'\t' read -r CIDR ATT_ID; do
        echo "  CIDR: $CIDR | Attachment: $ATT_ID | Route Table: $ROUTE_TABLE_ID"
        aws --profile "$AWS_PROFILE" ec2 create-transit-gateway-route \
          --transit-gateway-route-table-id "$ROUTE_TABLE_ID" \
          --destination-cidr-block "$CIDR" \
          --transit-gateway-attachment-id "$ATT_ID"

    done <<< "$ROUTES"
else
    echo "No propagated routes found for resource $RESOURCE_ID in route table $ROUTE_TABLE_ID."
fi