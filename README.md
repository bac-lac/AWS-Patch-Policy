# AWS-Patch-Policy
This project will use the AWS Systems Manager Quick Setup feature to create a patch policy.

## Environment Variables
The following environment variables are used to control the application at run-time. Mandatory variables are marked with an asterisk.

> ACCOUNT *: The AWS account number.
- Default value: ACCOUNT

> ENV *: The environment in which to deploy the solution.
- Default value: ENV

> EXTERNAL_ID *: External ID of the automation account role.
- Default value: EXTERNAL_ID

> PATCHGROUP_COUNT *: Number of patch groups to create.
- Default value: 1

> ROLE_ARN *: ARN of the role used by terraform.
- Default value: ROLE_ARN