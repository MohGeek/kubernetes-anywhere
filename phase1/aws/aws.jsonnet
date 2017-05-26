function(config)
  local tf = import "phase1/tf.jsonnet";
  local cfg = config.phase1;

  local kubeconfig(user, cluster, context) =
    std.manifestJson(
      tf.pki.kubeconfig_from_certs(
        user, cluster, context,
        cfg.cluster_name + "-root",
        "https://${aws_instance.master.public_ip}",
      ));

  local config_metadata_template = std.toString(config {
      master_ip: "${aws_instance.master.public_ip}",
      role: "%s",
      phase3 +: {
        addons_config: (import "phase3/all.jsonnet")(config),
      },
    });

  std.mergePatch({
    // AWS Configuration
    "provider": {
      "aws": {
        "region": "${var.region}",
        "access_key": "${var.access_key}",
        "secret_key": "${var.secret_key}"
      }
    },

     data: {
      template_file: {
        configure_master: {
          template: "${file(\"configure-vm.sh\")}",
          vars: {
            role: "master",
            root_ca_public_pem: "${base64encode(tls_self_signed_cert.%s-root.cert_pem)}" % cfg.cluster_name,
            apiserver_cert_pem: "${base64encode(tls_locally_signed_cert.%s-master.cert_pem)}" % cfg.cluster_name,
            apiserver_key_pem: "${base64encode(tls_private_key.%s-master.private_key_pem)}" % cfg.cluster_name,
            master_kubeconfig: kubeconfig(cfg.cluster_name + "-master", "local", "service-account-context"),
            node_kubeconfig: kubeconfig(cfg.cluster_name + "-node", "local", "service-account-context"),
            master_ip: "${aws_instance.master.public_ip}",
            nodes_dns_mappings: std.join("\n", node_name_to_ip),
            installer_container: config.phase2.installer_container,
            docker_registry: config.phase2.docker_registry,
            kubernetes_version: config.phase2.kubernetes_version,
          },
        },
        configure_node: {
          template: "${file(\"configure-vm.sh\")}",
          vars: {
            role: "node",
            root_ca_public_pem: "${base64encode(tls_self_signed_cert.%s-root.cert_pem)}" % cfg.cluster_name,
            apiserver_cert_pem: "${base64encode(tls_locally_signed_cert.%s-master.cert_pem)}" % cfg.cluster_name,
            apiserver_key_pem: "${base64encode(tls_private_key.%s-master.private_key_pem)}" % cfg.cluster_name,
            master_kubeconfig: kubeconfig(cfg.cluster_name + "-master", "local", "service-account-context"),
            node_kubeconfig: kubeconfig(cfg.cluster_name + "-node", "local", "service-account-context"),
            master_ip: "${aws_instance.master.public_ip}",
            nodes_dns_mappings: std.join("\n", node_name_to_ip),
            installer_container: config.phase2.installer_container,
            docker_registry: config.phase2.docker_registry,
            kubernetes_version: config.phase2.kubernetes_version,
          },
        },
      },
     },

     "resource": {
       "aws_instance": {
         "master": {
           "ami": "${var.ami}",
           "instance_type": "${var.instance_type}",
           "source_dest_check": false,
           "tags": {
             "Name": "${var.instance_name}-master"
           }
         },
         "nodes": {
           "count": "${var.nodes_count}",
           "ami": "${var.ami}",
           "instance_type": "${var.instance_type}",
           "source_dest_check": false,
           "tags": {
             "Name": "${var.instance_name}-nodes"
           }
         }
       },
       "aws_vpc": {
         "kubernetes_vpc": {
           "cidr_block": "10.0.0.0/8",
           "enable_dns_hostnames": true,
           "tags": {
             "Name": "${var.instance_name}-vpc"
           }
         }
       },
       "aws_subnet": {
         "kubernetes_subnet": {
           "vpc_id": "${aws_vpc.kubernetes_vpc.id}",
           "cidr_block": "10.240.0.0/16",
           "availability_zone": "${var.region}1",
           "tags": {
             "Name": "${var.instance_name}-subnet"
           }
         }
       },
       "aws_internet_gateway": {
           "kubernetes_gateway": {
             "vpc_id": "${aws_vpc.kubernetes_vpc.id}",
             "tags": {
               "Name": "${var.instance_name}-gateway"
             }
           }
       },
       "aws_route_table": {
         "kubernetes_routes": {
           "vpc_id": "${aws_vpc.kubernetes_vpc.id}",
           "route": {
             "cidr_block": "0.0.0.0/0",
             "gateway_id": "${aws_internet_gateway.kubernetes_gateway.id}"
           },
           "tags": {
             "Name": "${var.instance_name}-routes"
           }
         }
       },
       "aws_route_table_association": {
         "kubernetes_table_association": {
           "subnet_id": "${aws_subnet.kubernetes_subnet.id}",
           "route_table_id": "${aws_route_table.kubernetes_routes.id}"
         }
       },
       "aws_security_group": {
         "kubernetes_asg": {
           "name": "${var.instance_name}-asg",
           "ingress": {
             "from_port": 22,
             "to_port": 22,
             "protocol": "tcp",
             "cidr_blocks": ["0.0.0.0/0"]
           }
         }
       }
     },

     null_resource: {
       kubeconfig: {
         provisioner: [{
           "local-exec": {
             command: "echo '%s' > ./.tmp/kubeconfig.json" % kubeconfig(cfg.cluster_name + "-admin", cfg.cluster_name, cfg.cluster_name),
           },
         }],
       },
     },
    },
  }, tf.pki.cluster_tls(cfg.cluster_name, ["%(cluster_name)s-master" % cfg], ["${aws_instance.master.public_ip}"]))
