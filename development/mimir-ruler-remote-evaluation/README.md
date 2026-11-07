# Ruler remote evaluation

This environment runs the ruler with remote rule evaluation, where the ruler sends its queries to the query-frontend. Use it to check how ruler queries appear on the query-frontend side, for example the rule detail headers that `-ruler.query-frontend.enable-rule-detail-headers` attaches.

The environment runs two services built from the local source:

- **`mimir`:** Runs the distributor, ingester, querier, query-frontend, query-scheduler, and store-gateway. Its API is available at [http://localhost:8001](http://localhost:8001).
- **`ruler`:** Runs the ruler, which evaluates rules through the `mimir` service's query-frontend. Its API is available at [http://localhost:8002](http://localhost:8002).

Before you begin, ensure you have the following:

- Docker with Docker Compose.
- The Go version that `go.mod` requires.

## Rules

The ruler reads rules from the local [`rules`](./rules) directory, laid out as `rules/<TENANT>/<NAMESPACE>`. Each file is a namespace in Prometheus rule file format. The environment ships with rules for the `demo` tenant:

- `team-a_checkout.yaml`: An `availability` group with a recording rule and an alerting rule.
- `team-b_payments.yaml`: An `availability` group, reusing the group name from the other namespace, and a `team-b/payments/latency` group.

To change the rules, edit or add files under `rules/demo`. The ruler picks up changes within a few seconds.

## Run the environment

To build Mimir from source and start the environment, run:

```sh
./compose-up.sh -d
```

The query-frontend logs every query on a `query stats` log line, including the rule detail headers configured in `log_query_request_headers`. To view the ruler's queries, run:

```sh
docker compose logs -f mimir | grep 'msg="query stats"'
```

A rule evaluation query looks similar to the following:

```text
msg="query stats" component=query-frontend method=POST path=/prometheus/api/v1/query user_agent=mimir/unknown ... header_x_rule_name=CheckoutDown header_x_rule_type=alerting header_x_rule_source=mimir-ruler header_x_rule_namespace=team-a_checkout.yaml header_x_rule_group=availability status=success param_query="absent(up{job=\"checkout\"})"
```

To stop the environment, run:

```sh
./compose-down.sh
```

## Configure the query engine

The environment uses the Mimir query engine by default, in both the queriers and the query-frontend. To use the Prometheus engine instead, set these environment variables when you start the environment:

```sh
QUERY_ENGINE=prometheus FRONTEND_USE_MQE=false ./compose-up.sh -d
```

`QUERY_ENGINE` sets `-querier.query-engine`. `FRONTEND_USE_MQE` controls whether the query-frontend uses the Mimir query engine for sharding, splitting and caching, and remote execution.

To start the environment with the rule detail headers disabled, set `ENABLE_RULE_DETAIL_HEADERS=false`.

## Validate the rule detail headers

The `validate.sh` script checks the rule detail headers end to end. It restarts the environment three times:

- **Mimir query engine:** Checks that every rule's queries carry the expected headers, and that the queriers ran them on the Mimir query engine.
- **Prometheus engine:** Runs the same checks with the queriers on the Prometheus engine.
- **Headers disabled:** Checks that no query carries rule detail headers when the flag is disabled.

In the first two runs, the script also checks that the query restoring the alerts' `for` state carries no rule detail headers, because it isn't a rule evaluation.

To build the image and run the validation, run:

```sh
./compose-up.sh -d
./validate.sh
```

The script exits with a non-zero status if any check fails, and stops the environment when it finishes.
