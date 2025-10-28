<?php
/**
 * System: Suno Automation Gateway
 * Module: Front Controller
 * File URL: php/public/index.php
 * Purpose: Route incoming HTTP requests to the gateway handlers.
 */

declare(strict_types=1);

require __DIR__ . '/../src/gateway.php';

SunoGateway\handleRequest($_SERVER, function_exists('getallheaders') ? getallheaders() : [], (string) file_get_contents('php://input'));
