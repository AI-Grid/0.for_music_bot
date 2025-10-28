<?php
/**
 * System: Suno Automation Gateway
 * Module: Chat Proxy Gateway
 * File URL: php/src/gateway.php
 * Purpose: Expose an OpenAI-compatible endpoint that proxies requests to the FastAPI backend.
 */

declare(strict_types=1);

namespace SunoGateway;

use RuntimeException;

/**
 * Handle the current HTTP request by routing it to the appropriate handler.
 *
 * @param array<string, mixed> $server Superglobal server variables.
 * @param array<string, string> $headers Incoming HTTP headers.
 * @param string $body Raw HTTP request body.
 */
function handleRequest(array $server, array $headers, string $body): void
{
    $method = strtoupper((string) ($server['REQUEST_METHOD'] ?? 'GET'));
    $path = (string) parse_url((string) ($server['REQUEST_URI'] ?? '/'), PHP_URL_PATH);

    if ($method === 'POST' && $path === '/v1/chat/completions') {
        processChatCompletion($headers, $body);
        return;
    }

    sendJson(404, ['error' => 'Not Found']);
}

/**
 * Process an OpenAI-compatible chat completion request.
 *
 * @param array<string, string> $headers Incoming HTTP headers.
 * @param string $body Raw HTTP request body.
 */
function processChatCompletion(array $headers, string $body): void
{
    $body = trim($body);
    if ($body === '') {
        sendJson(400, ['error' => 'Request body must be valid JSON.']);
        return;
    }

    $authHeader = $headers['Authorization'] ?? $headers['authorization'] ?? '';
    $expectedApiKey = getenv('GATEWAY_CLIENT_API_KEY') ?: '';
    if ($expectedApiKey === '') {
        sendJson(500, ['error' => 'GATEWAY_CLIENT_API_KEY is not configured.']);
        return;
    }

    if (!validateBearerToken($authHeader, $expectedApiKey)) {
        sendJson(403, ['error' => 'Invalid or missing API key.']);
        return;
    }

    $isDiscordBot = isDiscordBotRequest($headers);
    if ($isDiscordBot && !validateDiscordPassword($headers)) {
        sendJson(403, ['error' => 'Invalid Discord bot password.']);
        return;
    }

    $payload = json_decode($body, true);
    if (!is_array($payload)) {
        sendJson(400, ['error' => 'Unable to parse JSON payload.']);
        return;
    }

    try {
        [$status, $responseBody] = forwardToBackend($body, $isDiscordBot ? ($headers['X-Discord-Password'] ?? $headers['x-discord-password'] ?? '') : '');
        header('Content-Type: application/json');
        http_response_code($status);
        echo $responseBody;
    } catch (RuntimeException $exception) {
        sendJson(502, ['error' => 'Failed to contact backend service.', 'detail' => $exception->getMessage()]);
    }
}

/**
 * Determine whether the request originated from the Discord bot integration.
 *
 * @param array<string, string> $headers Incoming HTTP headers.
 */
function isDiscordBotRequest(array $headers): bool
{
    $flag = strtolower($headers['X-Discord-Bot'] ?? $headers['x-discord-bot'] ?? '');
    return in_array($flag, ['1', 'true', 'yes'], true);
}

/**
 * Validate that the Discord password matches the expected configuration.
 *
 * @param array<string, string> $headers Incoming HTTP headers.
 */
function validateDiscordPassword(array $headers): bool
{
    $providedPassword = $headers['X-Discord-Password'] ?? $headers['x-discord-password'] ?? '';
    $expectedPassword = getenv('DISCORD_BOT_PASSWORD') ?: 'marty';

    if ($providedPassword === '') {
        return false;
    }

    return hash_equals($expectedPassword, $providedPassword);
}

/**
 * Validate the Authorization header using the configured API key.
 */
function validateBearerToken(string $authorizationHeader, string $expectedApiKey): bool
{
    if ($authorizationHeader === '') {
        return false;
    }

    if (stripos($authorizationHeader, 'Bearer ') !== 0) {
        return false;
    }

    $providedKey = trim(substr($authorizationHeader, 7));
    if ($providedKey === '') {
        return false;
    }

    return hash_equals($expectedApiKey, $providedKey);
}

/**
 * Forward the request payload to the backend chat endpoint.
 *
 * @return array{0:int,1:string}
 */
function forwardToBackend(string $payload, string $discordPassword): array
{
    $backendBase = rtrim(getenv('BACKEND_BASE_URL') ?: 'http://backend:8000', '/');
    $backendUrl = $backendBase . '/api/v1/chat/completions';
    $backendKey = getenv('BACKEND_CHAT_API_KEY') ?: '';

    if ($backendKey === '') {
        throw new RuntimeException('BACKEND_CHAT_API_KEY is not configured.');
    }

    $headers = [
        'Content-Type: application/json',
        'Authorization: Bearer ' . $backendKey,
    ];

    if ($discordPassword !== '') {
        $headers[] = 'X-Discord-Bot: true';
        $headers[] = 'X-Discord-Password: ' . $discordPassword;
    }

    $curl = curl_init($backendUrl);
    if ($curl === false) {
        throw new RuntimeException('Failed to initialize cURL.');
    }

    curl_setopt($curl, CURLOPT_POST, true);
    curl_setopt($curl, CURLOPT_POSTFIELDS, $payload);
    curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($curl, CURLOPT_HTTPHEADER, $headers);

    $responseBody = curl_exec($curl);
    if ($responseBody === false) {
        $errorMessage = curl_error($curl);
        curl_close($curl);
        throw new RuntimeException($errorMessage !== '' ? $errorMessage : 'Unknown cURL error.');
    }

    $statusCode = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
    curl_close($curl);

    return [
        $statusCode !== 0 ? $statusCode : 502,
        $responseBody,
    ];
}

/**
 * Emit a JSON response with the provided status code and payload.
 *
 * @param int $status HTTP status code to send.
 * @param array<string, mixed> $payload Structured payload to encode as JSON.
 */
function sendJson(int $status, array $payload): void
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}
