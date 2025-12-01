// Inline source for the template's registration custom resource Lambda.
// CommonJS on purpose: inline ZipFile code is stored as index.js and the
// nodejs22 runtime disables ESM auto-detection.
const { OrganizationsClient, DescribeOrganizationCommand } = require("@aws-sdk/client-organizations");
const https = require("https");

function putJson(u, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(u);
    const req = https.request({
      method: "PUT",
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) },
    }, (res) => {
      res.resume();
      if (res.statusCode >= 200 && res.statusCode < 300) resolve();
      else reject(new Error("PUT " + res.statusCode));
    });
    req.on("error", reject);
    req.end(body);
  });
}

function respond(event, status, extra) {
  const body = Object.assign({
    Status: status,
    PhysicalResourceId: event.PhysicalResourceId || event.RequestId,
    StackId: event.StackId,
    RequestId: event.RequestId,
    LogicalResourceId: event.LogicalResourceId,
  }, extra);
  return putJson(event.ResponseURL, JSON.stringify(body));
}

exports.handler = async function (event) {
  if (event.RequestType !== "Create") {
    return respond(event, "SUCCESS");
  }
  try {
    const org = await new OrganizationsClient().send(new DescribeOrganizationCommand());
    const p = event.ResourceProperties;
    const registration = {
      requestId: p.RequestId,
      accountId: p.AccountId,
      organizationId: org.Organization.Id,
      bootstrapRoleArn: p.BootstrapRoleArn,
      region: p.Region,
    };
    await putJson(p.Endpoint, JSON.stringify(registration));
    return respond(event, "SUCCESS", { Data: registration });
  } catch (err) {
    return respond(event, "FAILED", { Reason: String(err) });
  }
};
