local cfg = import "../../.config.json";
{
  ["aws-%(cluster_name)s.tf" % cfg.phase1]: (import "aws.jsonnet")(cfg),
}
