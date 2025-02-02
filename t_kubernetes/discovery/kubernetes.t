#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

BEGIN {
    my $token_var_file = "/var/run/secrets/kubernetes.io/serviceaccount/token";
    my $token_from_var = eval {`cat $token_var_file 2>/dev/null`};
    if ($token_from_var) {

        our $yaml_config = <<_EOC_;
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes: {}
_EOC_
        our $token_file = $token_var_file;
        our $token_value = $token_from_var;

    }

    my $token_tmp_file = "/tmp/var/run/secrets/kubernetes.io/serviceaccount/token";
    my $token_from_tmp = eval {`cat $token_tmp_file 2>/dev/null`};
    if ($token_from_tmp) {

        our $yaml_config = <<_EOC_;
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: /tmp/var/run/secrets/kubernetes.io/serviceaccount/token
_EOC_
        our $token_file = $token_tmp_file;
        our $token_value = $token_from_tmp;
    }

    our $scale_ns_c = <<_EOC_;
[
  {
    "op": "replace_subsets",
    "name": "ep",
    "namespace": "ns-c",
    "subsets": [
      {
        "addresses": [
          {
            "ip": "10.0.0.1"
          }
        ],
        "ports": [
          {
            "name": "p1",
            "port": 5001
          }
        ]
      }
    ]
  }
]
_EOC_

}

use t::APISIX 'no_plan';

repeat_each(1);
log_level('debug');
no_root_location();
no_shuffle();
workers(4);

add_block_preprocessor(sub {
    my ($block) = @_;

    my $apisix_yaml = $block->apisix_yaml // <<_EOC_;
routes: []
#END
_EOC_

    $block->set_value("apisix_yaml", $apisix_yaml);

    my $main_config = $block->main_config // <<_EOC_;
env KUBERNETES_SERVICE_HOST=127.0.0.1;
env KUBERNETES_SERVICE_PORT=6443;
env KUBERNETES_CLIENT_TOKEN=$::token_value;
env KUBERNETES_CLIENT_TOKEN_FILE=$::token_file;
_EOC_

    $block->set_value("main_config", $main_config);

    my $config = $block->config // <<_EOC_;
        location /queries {
            content_by_lua_block {
              local core = require("apisix.core")
              local d = require("apisix.discovery.kubernetes")

              ngx.sleep(1)

              ngx.req.read_body()
              local request_body = ngx.req.get_body_data()
              local queries = core.json.decode(request_body)
              local response_body = "{"
              for _,query in ipairs(queries) do
                local nodes = d.nodes(query)
                if nodes==nil or #nodes==0 then
                    response_body=response_body.." "..0
                else
                    response_body=response_body.." "..#nodes
                end
              end
              ngx.say(response_body.." }")
            }
        }

        location /operators {
            content_by_lua_block {
                local http = require("resty.http")
                local core = require("apisix.core")
                local ipairs = ipairs

                ngx.req.read_body()
                local request_body = ngx.req.get_body_data()
                local operators = core.json.decode(request_body)

                core.log.info("get body ", request_body)
                core.log.info("get operators ", #operators)
                for _, op in ipairs(operators) do
                    local method, path, body
                    local headers = {
                        ["Host"] = "127.0.0.1:6445"
                    }

                    if op.op == "replace_subsets" then
                        method = "PATCH"
                        path = "/api/v1/namespaces/" .. op.namespace .. "/endpoints/" .. op.name
                        if #op.subsets == 0 then
                            body = '[{"path":"/subsets","op":"replace","value":[]}]'
                        else
                            local t = { { op = "replace", path = "/subsets", value = op.subsets } }
                            body = core.json.encode(t, true)
                        end
                        headers["Content-Type"] = "application/json-patch+json"
                    end

                    if op.op == "replace_labels" then
                        method = "PATCH"
                        path = "/api/v1/namespaces/" .. op.namespace .. "/endpoints/" .. op.name
                        local t = { { op = "replace", path = "/metadata/labels", value = op.labels } }
                        body = core.json.encode(t, true)
                        headers["Content-Type"] = "application/json-patch+json"
                    end

                    local httpc = http.new()
                    core.log.info("begin to connect ", "127.0.0.1:6445")
                    local ok, message = httpc:connect({
                        scheme = "http",
                        host = "127.0.0.1",
                        port = 6445,
                    })
                    if not ok then
                        core.log.error("connect 127.0.0.1:6445 failed, message : ", message)
                        ngx.say("FAILED")
                    end
                    local res, err = httpc:request({
                        method = method,
                        path = path,
                        headers = headers,
                        body = body,
                    })
                    if err ~= nil then
                        core.log.err("operator k8s cluster error: ", err)
                        return 500
                    end
                    if res.status ~= 200 and res.status ~= 201 and res.status ~= 409 then
                        return res.status
                    end
                end
                ngx.say("DONE")
            }
        }

_EOC_

    $block->set_value("config", $config);
});

run_tests();

__DATA__

=== TEST 1: create namespace and endpoints
--- yaml_config eval: $::yaml_config
--- request
POST /operators
[
  {
    "op": "replace_subsets",
    "namespace": "ns-a",
    "name": "ep",
    "subsets": [
      {
        "addresses": [
          {
            "ip": "10.0.0.1"
          },
          {
            "ip": "10.0.0.2"
          }
        ],
        "ports": [
          {
            "name": "p1",
            "port": 5001
          }
        ]
      },
      {
        "addresses": [
          {
            "ip": "20.0.0.1"
          },
          {
            "ip": "20.0.0.2"
          }
        ],
        "ports": [
          {
            "name": "p2",
            "port": 5002
          }
        ]
      }
    ]
  },
  {
    "op": "create_namespace",
    "name": "ns-b"
  },
  {
    "op": "replace_subsets",
    "namespace": "ns-b",
    "name": "ep",
    "subsets": [
      {
        "addresses": [
          {
            "ip": "10.0.0.1"
          },
          {
            "ip": "10.0.0.2"
          }
        ],
        "ports": [
          {
            "name": "p1",
            "port": 5001
          }
        ]
      },
      {
        "addresses": [
          {
            "ip": "20.0.0.1"
          },
          {
            "ip": "20.0.0.2"
          }
        ],
        "ports": [
          {
            "name": "p2",
            "port": 5002
          }
        ]
      }
    ]
  },
  {
    "op": "create_namespace",
    "name": "ns-c"
  },
  {
    "op": "replace_subsets",
    "namespace": "ns-c",
    "name": "ep",
    "subsets": [
      {
        "addresses": [
          {
            "ip": "10.0.0.1"
          },
          {
            "ip": "10.0.0.2"
          }
        ],
        "ports": [
          {
            "port": 5001
          }
        ]
      },
      {
        "addresses": [
          {
            "ip": "20.0.0.1"
          },
          {
            "ip": "20.0.0.2"
          }
        ],
        "ports": [
          {
            "port": 5002
          }
        ]
      }
    ]
  }
]
--- more_headers
Content-type: application/json
--- error_code: 200
--- no_error_log
[error]



=== TEST 2: use default parameters
--- yaml_config eval: $::yaml_config
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 2 2 }
--- no_error_log
[error]



=== TEST 3: use specify parameters
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    service:
      host: "127.0.0.1"
      port: "6443"
    client:
      token: "${KUBERNETES_CLIENT_TOKEN}"
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 2 2 }
--- no_error_log
[error]



=== TEST 4: use specify environment parameters
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    service:
      host: ${KUBERNETES_SERVICE_HOST}
      port: ${KUBERNETES_SERVICE_PORT}
    client:
      token: ${KUBERNETES_CLIENT_TOKEN}
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 2 2 }
--- no_error_log
[error]



=== TEST 5: use token_file
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 2 2 }
--- no_error_log
[error]



=== TEST 6: use http
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    service:
      schema: http
      host: "127.0.0.1"
      port: "6445"
    client:
      token: ""
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 2 2 }
--- no_error_log
[error]



=== TEST 7: use namespace selector equal
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      equal: ns-a
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 0 0 0 0 }
--- no_error_log
[error]



=== TEST 8: use namespace selector not_equal
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      not_equal: ns-a
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 0 0 2 2 2 2 }
--- no_error_log
[error]



=== TEST 9: use namespace selector match
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      match: [ns-a,ns-b]
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 0 0 }
--- no_error_log
[error]



=== TEST 10: use namespace selector match with regex
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      match: ["ns-[ab]"]
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 2 2 2 2 0 0 }
--- no_error_log
[error]



=== TEST 11: use namespace selector not_match
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      not_match: ["ns-a"]
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 0 0 2 2 2 2 }
--- no_error_log
[error]



=== TEST 12: use namespace selector not_match with regex
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    namespace_selector:
      not_match: ["ns-[ab]"]
--- request
GET /queries
["ns-a/ep:p1","ns-a/ep:p2","ns-b/ep:p1","ns-b/ep:p2","ns-c/ep:5001","ns-c/ep:5002"]
--- more_headers
Content-type: application/json
--- response_body eval
qr{ 0 0 0 0 2 2 }
--- no_error_log
[error]



=== TEST 13: use label selector
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false
discovery:
  kubernetes:
    client:
      token_file: ${KUBERNETES_CLIENT_TOKEN_FILE}
    label_selector: |-
       first=1,second
--- request eval
[

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-a\",\"labels\":{}}]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-b\",\"labels\":{}}]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-c\",\"labels\":{}}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-a\",\"labels\":{\"first\":\"1\" }}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-b\",\"labels\":{\"first\":\"1\",\"second\":\"o\" }}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-c\",\"labels\":{\"first\":\"2\",\"second\":\"o\" }}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-c\",\"labels\":{\"first\":\"1\" }}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

"POST /operators
[{\"op\":\"replace_labels\",\"name\":\"ep\",\"namespace\":\"ns-c\",\"labels\":{\"first\":\"1\",\"second\":\"o\" }}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-b/ep:p1\",\"ns-c/ep:5001\"]",

]
--- response_body eval
[
    "DONE\n",
    "DONE\n",
    "DONE\n",
    "{ 0 0 0 }\n",
    "DONE\n",
    "{ 0 0 0 }\n",
    "DONE\n",
    "{ 0 2 0 }\n",
    "DONE\n",
    "{ 0 2 0 }\n",
    "DONE\n",
    "{ 0 2 0 }\n",
    "DONE\n",
    "{ 0 2 2 }\n",
]
--- no_error_log
[error]



=== TEST 15: scale endpoints
--- yaml_config eval: $::yaml_config
--- request eval
[
"GET /queries
[\"ns-a/ep:p1\",\"ns-a/ep:p2\"]",

"POST /operators
[{\"op\":\"replace_subsets\",\"name\":\"ep\",\"namespace\":\"ns-a\",\"subsets\":[]}]",

"GET /queries
[\"ns-a/ep:p1\",\"ns-a/ep:p2\"]",

"GET /queries
[\"ns-c/ep:5001\",\"ns-c/ep:5002\",\"ns-c/ep:p1\"]",

"POST /operators
$::scale_ns_c",

"GET /queries
[\"ns-c/ep:5001\",\"ns-c/ep:5002\",\"ns-c/ep:p1\"]",

]
--- response_body eval
[
    "{ 2 2 }\n",
    "DONE\n",
    "{ 0 0 }\n",
    "{ 2 2 0 }\n",
    "DONE\n",
    "{ 0 0 1 }\n",
]
--- no_error_log
[error]
