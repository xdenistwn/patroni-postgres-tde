<?php

/**
 * Laravel Multi-Tenant Database Configuration
 * =============================================
 *
 * This sample shows how to configure Laravel to use HAProxy as the
 * connection bridge to multiple Patroni PostgreSQL clusters.
 *
 * Architecture:
 *   Laravel App  →  HAProxy  →  PgBouncer  →  PostgreSQL
 *
 * Port Scheme (defined in haproxy.cfg):
 *   Read/Write (Primary) : 5000 + cluster_index
 *   Read-Only  (Replica) : 5100 + cluster_index
 *
 * Place this in your config/database.php under 'connections'.
 */

return [

    /*
    |--------------------------------------------------------------------------
    | Default Database Connection Name
    |--------------------------------------------------------------------------
    */
    'default' => env('DB_CONNECTION', 'tenant_a'),

    'connections' => [

        /*
        |------------------------------------------------------------------
        | Tenant A - Cluster 1
        |------------------------------------------------------------------
        | Uses Laravel's built-in read/write splitting so that SELECT
        | queries automatically go to the replica pool while INSERT,
        | UPDATE, DELETE go to the primary.
        |------------------------------------------------------------------
        */
        'tenant_a' => [
            'driver'   => 'pgsql',

            // Read/Write split — both ports are HAProxy frontends backed by Patroni health checks.
            // :5001 always routes to the current primary (GET /primary).
            // :5101 routes to replica(s), falls back to primary when no replica is available.
            'read' => [
                'host' => env('DB_AIRLINEDENI_HOST', '127.0.0.1'),
                'port' => env('DB_AIRLINEDENI_READ_PORT', 5101),
            ],
            'write' => [
                'host' => env('DB_AIRLINEDENI_HOST', '127.0.0.1'),
                'port' => env('DB_AIRLINEDENI_WRITE_PORT', 5001),
            ],

            // After any write, keep subsequent queries on the write connection
            // for the rest of the request to avoid replication-lag reads.
            'sticky' => true,

            'database' => env('DB_AIRLINEDENI_DATABASE', 'postgres'),
            'username' => env('DB_AIRLINEDENI_USERNAME', 'postgres'),
            'password' => env('DB_AIRLINEDENI_PASSWORD', ''),
            'charset'  => 'utf8',
            'prefix'   => '',
            'sslmode'  => 'prefer',
        ],

        /*
        |------------------------------------------------------------------
        | Tenant B - Alpha Cluster
        |------------------------------------------------------------------
        */
        'tenant_b' => [
            'driver'   => 'pgsql',
            
            'read' => [
                'host' => env('DB_HOST_PROXY', 'haproxy'),
                'port' => env('DB_PORT_B_RO', 5102),
            ],
            'write' => [
                'host' => env('DB_HOST_PROXY', 'haproxy'),
                'port' => env('DB_PORT_B_RW', 5002),
            ],

            'sticky' => true,

            'database' => env('DB_DATABASE_B', 'app_tenant_b'),
            'username' => env('DB_USERNAME_B', 'app_user'),
            'password' => env('DB_PASSWORD_B', ''),
            'charset'  => 'utf8',
            'prefix'   => '',
            'sslmode'  => 'prefer',
        ],

    ],

];
