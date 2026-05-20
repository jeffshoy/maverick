import azure.functions as func
import logging
import os
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="vmss_autoscale")
def vmss_autoscale(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("VMSS autoscale function triggered.")

    try:
        alert = req.get_json()
    except ValueError:
        return func.HttpResponse("Invalid JSON payload", status_code=400)

    # webhook_properties land in customProperties under the common alert schema
    scale_direction = (
        alert.get("data", {})
             .get("customProperties", {})
             .get("scaleDirection", "out")
    )
    logging.info(f"Scale direction: {scale_direction}")

    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    resource_group  = os.environ["VMSS_RESOURCE_GROUP"]
    vmss_name       = os.environ["VMSS_NAME"]
    scale_out_cap   = int(os.environ.get("SCALE_OUT_CAPACITY", 5))
    scale_in_cap    = int(os.environ.get("SCALE_IN_CAPACITY", 1))

    credential     = ManagedIdentityCredential()
    compute_client = ComputeManagementClient(credential, subscription_id)

    vmss             = compute_client.virtual_machine_scale_sets.get(resource_group, vmss_name)
    current_capacity = vmss.sku.capacity
    logging.info(f"Current VMSS capacity: {current_capacity}")

    if scale_direction == "out":
        new_capacity = min(current_capacity + 1, scale_out_cap)
    elif scale_direction == "in":
        new_capacity = max(current_capacity - 1, scale_in_cap)
    else:
        return func.HttpResponse(f"Unknown scale direction: {scale_direction}", status_code=400)

    if new_capacity == current_capacity:
        msg = f"Already at limit ({current_capacity}). No scaling needed."
        logging.info(msg)
        return func.HttpResponse(msg, status_code=200)

    compute_client.virtual_machine_scale_sets.begin_update(
        resource_group,
        vmss_name,
        {"sku": {"capacity": new_capacity, "name": vmss.sku.name, "tier": vmss.sku.tier}}
    ).result()

    msg = f"Scaled {scale_direction}: {current_capacity} -> {new_capacity} instances."
    logging.info(msg)
    return func.HttpResponse(msg, status_code=200)
